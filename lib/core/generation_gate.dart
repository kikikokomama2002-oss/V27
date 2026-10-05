/// Monotonic request-generation gate for asynchronous workflows.
///
/// Starting a new request invalidates every older request. The gate contains
/// no timers or global state and is safe to use from a single Dart isolate.
class GenerationGate {
  int _generation = 0;

  int begin() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;

  int get current => _generation;
}
