require "fiber"
{% if flag?(:preview_mt) %}
  require "crystal/spin_lock"
{% else %}
  require "crystal/null_lock"
{% end %}

# A `Channel` enables concurrent communication between fibers.
#
# They allow communicating data between fibers without sharing memory and without having to worry about locks, semaphores or other special structures.
#
# ```
# channel = Channel(Int32).new
#
# spawn do
#   channel.send(0)
#   channel.send(1)
# end
#
# channel.receive # => 0
# channel.receive # => 1
# ```
class Channel(T)
  {% if flag?(:preview_mt) %}
    @lock = Crystal::SpinLock.new
  {% else %}
    @lock = Crystal::NullLock.new
  {% end %}

  @queue : Deque(T)?

  module SelectAction
    abstract def execute(&block)
    abstract def wait(context : SelectContext)
    abstract def unwait
    abstract def result
    abstract def lock_object_id
    abstract def lock
    abstract def unlock
  end

  enum SelectState
    None   = 0
    Active = 1
    Done   = 2
  end

  private class SelectContext
    @state : Pointer(Atomic(SelectState))
    property action : SelectAction
    @activated = false

    def initialize(@state, @action)
    end

    def activated?
      @activated
    end

    def try_trigger : Bool
      _, succeed = @state.value.compare_and_set(SelectState::Active, SelectState::Done)
      if succeed
        @activated = true
      end
      succeed
    end
  end

  class ClosedError < Exception
    def initialize(msg = "Channel is closed")
      super(msg)
    end
  end

  enum DeliveryState
    None
    Delivered
    Closed
  end

  def initialize(@capacity = 0)
    @closed = false
    @senders = Deque({Fiber, T, SelectContext?}).new
    @receivers = Deque({Fiber, Pointer(T), Pointer(DeliveryState), SelectContext?}).new
    if capacity > 0
      @queue = Deque(T).new(capacity)
    end
  end

  def close
    @closed = true

    @senders.each &.first.restore

    @receivers.each do |receiver|
      receiver[2].value = DeliveryState::Closed
      receiver[0].restore
    end

    @senders.clear
    @receivers.clear
    nil
  end

  def closed?
    @closed
  end

  def send(value : T)
    @lock.sync do
      raise_if_closed

      send_internal(value) do
        @senders << {Fiber.current, value, nil}
        @lock.unsync do
          Crystal::Scheduler.reschedule
        end
        raise_if_closed
      end

      self
    end
  end

  protected def send_internal(value : T)
    if receiver = dequeue_receiver
      receiver[1].value = value
      receiver[2].value = DeliveryState::Delivered
      receiver[0].restore
    elsif (queue = @queue) && queue.size < @capacity
      queue << value
    else
      yield
    end
  end

  # Receives a value from the channel.
  # If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.
  #
  # Raises `ClosedError` if the channel is closed or closes while waiting for receive.
  #
  # ```
  # channel = Channel(Int32).new
  # channel.send(1)
  # channel.receive # => 1
  # ```
  def receive
    receive_impl { raise ClosedError.new }
  end

  # Receives a value from the channel.
  # If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.
  #
  # Returns `nil` if the channel is closed or closes while waiting for receive.
  def receive?
    receive_impl { return nil }
  end

  def receive_impl
    @lock.sync do
      yield if @closed

      receive_internal do
        value = uninitialized T
        state = DeliveryState::None
        @receivers << {Fiber.current, pointerof(value), pointerof(state), nil}
        @lock.unsync do
          Crystal::Scheduler.reschedule
        end

        case state
        when DeliveryState::Delivered
          value
        when DeliveryState::Closed
          yield
        else
          raise "BUG: Fiber was awaken without channel delivery state set"
        end
      end
    end
  end

  def receive_internal
    if (queue = @queue) && !queue.empty?
      deque_value = queue.shift
      if sender = dequeue_sender
        sender[0].restore
        queue << sender[1]
      end
      deque_value
    elsif sender = dequeue_sender
      sender[0].restore
      sender[1]
    else
      yield
    end
  end

  private def dequeue_receiver
    while receiver = @receivers.shift?
      if (select_context = receiver[3]) && !select_context.try_trigger
        next
      end

      break
    end

    receiver
  end

  private def dequeue_sender
    while sender = @senders.shift?
      if (select_context = sender[2]) && !select_context.try_trigger
        next
      end

      break
    end

    sender
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp)
    pp.text inspect
  end

  protected def wait_for_receive(value, state, context)
    @receivers << {Fiber.current, value, state, context}
  end

  protected def unwait_for_receive
    @receivers.delete_if { |r| r[0] == Fiber.current }
  end

  protected def wait_for_send(value, context)
    @senders << {Fiber.current, value, context}
  end

  protected def unwait_for_send
    @senders.delete_if { |r| r[0] == Fiber.current }
  end

  protected def raise_if_closed
    raise ClosedError.new if @closed
  end

  def self.receive_first(*channels)
    receive_first channels
  end

  def self.receive_first(channels : Tuple | Array)
    self.select(channels.map(&.receive_select_action))[1]
  end

  def self.send_first(value, *channels)
    send_first value, channels
  end

  def self.send_first(value, channels : Tuple | Array)
    self.select(channels.map(&.send_select_action(value)))
    nil
  end

  def self.select(*ops : SelectAction)
    self.select ops
  end

  def self.select(ops : Indexable(SelectAction), has_else = false)
    # Sort the operations by the channel they contain
    # This is to avoid deadlocks between concurrent `select` calls
    ops_locks = ops
      .to_a
      .uniq(&.lock_object_id)
      .sort_by(&.lock_object_id)

    ops_locks.each &.lock

    ops.each_with_index do |op, index|
      ignore = false
      result = op.execute { ignore = true; nil }

      unless ignore
        ops_locks.each &.unlock
        return index, result
      end
    end

    if has_else
      ops_locks.each &.unlock
      return ops.size, nil
    end

    state = Atomic(SelectState).new(SelectState::Active)

    contexts = ops.map_with_index do |op, index|
      context = SelectContext.new(pointerof(state), op)
      op.wait(context)
      context
    end

    ops_locks.each &.unlock
    Crystal::Scheduler.reschedule

    ops.each do |op|
      op.lock
      op.unwait
      op.unlock
    end

    contexts.each_with_index do |context, index|
      if context.activated?
        return index, context.action.result
      end
    end

    raise "BUG: Fiber was awaken from select but no action was activated"
  end

  # :nodoc:
  def send_select_action(value : T)
    SendAction.new(self, value)
  end

  # :nodoc:
  def receive_select_action
    ReceiveAction.new(self)
  end

  # :nodoc:
  class ReceiveAction(T)
    include SelectAction
    property value : T
    property state : DeliveryState

    def initialize(@channel : Channel(T))
      @value = uninitialized T
      @state = DeliveryState::None
    end

    def execute
      @channel.receive_internal { yield }
    end

    def result
      @value
    end

    def wait(context : SelectContext)
      @channel.wait_for_receive(pointerof(@value), pointerof(@state), context)
    end

    def unwait
      @channel.unwait_for_receive
    end

    def lock_object_id
      @channel.object_id
    end

    def lock
      @channel.@lock.lock
    end

    def unlock
      @channel.@lock.unlock
    end
  end

  # :nodoc:
  class SendAction(C, T)
    include SelectAction

    def initialize(@channel : C, @value : T)
    end

    def execute
      @channel.send_internal(@value) { yield }
    end

    def result
    end

    def wait(context : SelectContext)
      @channel.wait_for_send(@value, context)
    end

    def unwait
      @channel.unwait_for_send
    end

    def lock_object_id
      @channel.object_id
    end

    def lock
      @channel.@lock.lock
    end

    def unlock
      @channel.@lock.unlock
    end
  end
end
