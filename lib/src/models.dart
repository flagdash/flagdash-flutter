class EvaluationContext {
  const EvaluationContext(
      {this.userId, this.unitId, this.attributes = const {}});

  final String? userId;
  final String? unitId;
  final Map<String, String> attributes;

  Map<String, String> toQuery() => <String, String>{
        ...attributes,
        if (userId != null) 'user_id': userId!,
        if (unitId != null) 'unit_id': unitId!,
      };
}

class FlagDetail<T> {
  const FlagDetail(
      {required this.key,
      required this.value,
      required this.reason,
      this.variationKey});
  final String key;
  final T value;
  final String reason;
  final String? variationKey;
}

class AiConfig {
  const AiConfig(
      {required this.fileName,
      required this.fileType,
      required this.content,
      this.folder});
  final String fileName;
  final String fileType;
  final String content;
  final String? folder;

  factory AiConfig.fromJson(Map<String, dynamic> json) => AiConfig(
        fileName: json['file_name'] as String,
        fileType: json['file_type'] as String,
        content: json['content'] as String,
        folder: json['folder'] as String?,
      );
}

class ExperimentAssignment {
  const ExperimentAssignment(
      {required this.key,
      required this.status,
      required this.variantKey,
      required this.parameters});
  final String key;
  final String status;
  final String variantKey;
  final Map<String, dynamic> parameters;

  factory ExperimentAssignment.fromJson(Map<String, dynamic> json) =>
      ExperimentAssignment(
        key: json['key'] as String,
        status: json['status'] as String,
        variantKey: json['variant_key'] as String,
        parameters:
            Map<String, dynamic>.from(json['parameters'] as Map? ?? const {}),
      );
}
