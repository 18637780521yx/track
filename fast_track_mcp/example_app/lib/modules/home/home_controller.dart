import 'package:get/get.dart';

import '../../demo_api.dart';

class HomeController extends GetxController {
  final items = <Map<String, dynamic>>[].obs;
  final loading = true.obs;
  final error = RxnString();

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    error.value = null;
    try {
      final list = await DemoApi.instance.fetchHomeList();
      items.assignAll(list);
      loading.value = false;
    } catch (e) {
      error.value = '$e';
      loading.value = false;
      // Fallback so scroll smoke still works if HTTP fails.
      items.assignAll(
        List.generate(
          60,
          (i) => {
            'id': i,
            'title': '列表项 #$i',
            'subtitle': 'Phase2 滑动性能测试 · item $i',
          },
        ),
      );
    }
  }

  Future<void> refreshList() async {
    await load();
    Get.snackbar(
      '刷新',
      error.value == null ? '已刷新' : '刷新失败，已用本地列表',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }
}
