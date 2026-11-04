class UiElement {
  const UiElement({
    required this.label,
    this.value,
    this.isButton = false,
    this.isTextField = false,
    this.rect,
  });

  final String label;
  final String? value;
  final bool isButton;
  final bool isTextField;
  final Map<String, double>? rect;

  Map<String, dynamic> toJson() => {
        'label': label,
        'value': value,
        'isButton': isButton,
        'isTextField': isTextField,
        if (rect != null) 'rect': rect,
      };

  factory UiElement.fromJson(Map<String, dynamic> json) {
    Map<String, double>? rect;
    final raw = json['rect'];
    if (raw is Map) {
      rect = raw.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
    }
    return UiElement(
      label: json['label'] as String? ?? '',
      value: json['value'] as String?,
      isButton: json['isButton'] == true,
      isTextField: json['isTextField'] == true,
      rect: rect,
    );
  }
}

class UiDumpData {
  const UiDumpData({
    required this.elements,
    this.note,
  });

  final List<UiElement> elements;
  final String? note;

  Map<String, dynamic> toJson() => {
        'elements': elements.map((e) => e.toJson()).toList(),
        if (note != null) 'note': note,
      };

  factory UiDumpData.fromJson(Map<String, dynamic> json) {
    final list = <UiElement>[];
    final raw = json['elements'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          list.add(UiElement.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return UiDumpData(
      elements: list,
      note: json['note'] as String?,
    );
  }
}
