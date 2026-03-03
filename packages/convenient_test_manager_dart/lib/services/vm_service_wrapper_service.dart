abstract class VmServiceWrapperService {
  bool get connected;

  String get workerVmHost;
  int get workerVmPort;
  void setWorkerVmEndpoint({required String host, required int port});

  Future<void> connect();
  bool get hotRestartActing;

  bool get hotRestartAvailable;
  Future<void> hotRestartRaw();

  void hotRestartThrottled();
}
