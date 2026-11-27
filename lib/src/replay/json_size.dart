/// About how long `jsonEncode(value)` is, without building the string: for
/// the replay budgets, which must not cost an encoding of every clip on the
/// UI isolate. Strings count their characters and quotes (escapes, rare in
/// replay events, are left out), integers their digits.
int approxJsonLength(Object? value) {
  switch (value) {
    case null:
      return 4;
    case String():
      return value.length + 2;
    case bool():
      return value ? 4 : 5;
    case int():
      return _digits(value);
    case double():
      return value.toString().length;
    case Map():
      var n = 2 + (value.isEmpty ? 0 : value.length - 1);
      for (final MapEntry(:key, :value) in value.entries) {
        n += (key is String ? key.length + 2 : '$key'.length + 2) +
            1 +
            approxJsonLength(value);
      }
      return n;
    case List():
      var n = 2 + (value.isEmpty ? 0 : value.length - 1);
      for (final item in value) {
        n += approxJsonLength(item);
      }
      return n;
  }
  return 2;
}

int _digits(int v) {
  var n = v < 0 ? 2 : 1;
  var x = v.abs();
  while (x >= 10) {
    x ~/= 10;
    n++;
  }
  return n;
}
