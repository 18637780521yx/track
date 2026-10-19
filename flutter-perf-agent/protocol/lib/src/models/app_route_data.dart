/// Current app route as reported by PerfBridge `/app/route`.
class AppRouteData {
  const AppRouteData({required this.route});

  /// Logical page id, e.g. `/login`, `/home`, `/home#mine`.
  final String route;

  Map<String, dynamic> toJson() => {'route': route};

  factory AppRouteData.fromJson(Map<String, dynamic> json) => AppRouteData(
        route: json['route']?.toString() ?? '',
      );
}
