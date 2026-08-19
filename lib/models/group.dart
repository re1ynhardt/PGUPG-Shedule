class Group {
  final String id; // numeric id from URL, e.g. 1839071781541074559
  final String name; // e.g. "АТ-501"
  final String faculty; // e.g. "Автоматизация и интеллектуальные технологии"
  final int course; // 1..6
  final String form; // "Очная форма" | "Заочная форма" | "Очно-заочная форма"

  const Group({
    required this.id,
    required this.name,
    required this.faculty,
    required this.course,
    required this.form,
  });

  String get url => 'https://rasp.pgups.ru/schedule/group/$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'faculty': faculty,
        'course': course,
        'form': form,
      };

  factory Group.fromJson(Map<String, dynamic> json) => Group(
        id: json['id'] as String,
        name: json['name'] as String,
        faculty: json['faculty'] as String,
        course: json['course'] as int,
        form: json['form'] as String,
      );

  @override
  bool operator ==(Object other) => other is Group && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
