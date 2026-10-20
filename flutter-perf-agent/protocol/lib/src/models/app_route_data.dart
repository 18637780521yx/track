/// Current app route as reported by PerfBridge `/app/route`.
class AppRouteData {
  const AppRouteData({
    required this.route,
    this.transitionKind,
    this.from,
    this.to,
  });

  /// Logical page id, e.g. `/login`, `/home`, `/home#mine`.
  final String route;

  /// Last observed transition: `push` / `pop` / `replace` / `route_change`.
  final String? transitionKind;
  final String? from;
  final String? to;

  Map<String, dynamic> toJson() => {
        'route': route,
        if (transitionKind != null) 'transitionKind': transitionKind,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
      };

  factory AppRouteData.fromJson(Map<String, dynamic> json) => AppRouteData(
        route: json['route']?.toString() ?? '',
        transitionKind: json['transitionKind']?.toString(),
        from: json['from']?.toString(),
        to: json['to']?.toString(),
      );
}
