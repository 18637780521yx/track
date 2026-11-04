class WaitData {
  const WaitData({required this.waitedMs, required this.frames});

  final int waitedMs;
  final int frames;

  Map<String, dynamic> toJson() => {
        'waitedMs': waitedMs,
        'frames': frames,
      };

  factory WaitData.fromJson(Map<String, dynamic> json) => WaitData(
        waitedMs: (json['waitedMs'] as num?)?.toInt() ?? 0,
        frames: (json['frames'] as num?)?.toInt() ?? 0,
      );
}
