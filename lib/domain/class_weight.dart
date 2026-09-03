import '../data/models/class_category.dart';

/// What a class counts as before the slot itself says otherwise. A subject
/// filed in no category is worth one.
int weightFor(ClassCategory? category) => category?.weight ?? 1;

const List<int> kClassWeights = <int>[0, 1, 2, 3];

String classWeightLabel(int weight) => switch (weight) {
      0 => 'Does not count',
      1 => '1 class',
      _ => '$weight classes',
    };
