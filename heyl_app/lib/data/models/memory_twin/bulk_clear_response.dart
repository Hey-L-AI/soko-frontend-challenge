class BulkClearResponse {
  final Map<String, int> deleted;
  final bool killSwitchEngaged;

  const BulkClearResponse({
    required this.deleted,
    required this.killSwitchEngaged,
  });

  int get totalDeleted => deleted.values.fold(0, (a, b) => a + b);

  factory BulkClearResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['deleted'] as Map<String, dynamic>? ?? const {};
    return BulkClearResponse(
      deleted: raw.map((k, v) => MapEntry(k, (v as num).toInt())),
      killSwitchEngaged: json['kill_switch_engaged'] as bool? ?? false,
    );
  }
}
