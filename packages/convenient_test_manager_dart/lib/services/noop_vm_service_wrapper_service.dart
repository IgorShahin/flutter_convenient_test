import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';

class NoOpVmServiceWrapperService extends VmServiceWrapperService {
  @override
  bool get connected => false;

  @override
  Future<void> connect() async {}

  @override
  bool get hotRestartActing => false;

  @override
  bool get hotRestartAvailable => false;

  @override
  Future<void> hotRestartRaw() async {}

  @override
  void hotRestartThrottled() {}
}
