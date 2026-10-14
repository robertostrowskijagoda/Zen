T? castCopyWithValue<T>(Object? value, {required String fieldName}) {
  if (value == null || value is T) {
    return value as T?;
  }
  throw ArgumentError.value(
    value,
    fieldName,
    'Expected ${T.toString()} or null.',
  );
}
