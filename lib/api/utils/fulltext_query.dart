import 'package:paperless_mobile/api/models/query_parameters/date_range_query.dart';

/// Paperless query syntax uses Boolean operators, not comma-separated values.
/// https://docs.paperless-ngx.com/usage/#searching
String composeFulltextQuery(Iterable<String> components) {
  final queries = components.where((query) => query.isNotEmpty).toList();
  if (queries.length <= 1) return queries.join();
  return queries.map((query) => '($query)').join(' AND ');
}

class ParsedFulltextQuery {
  final String? queryText;
  final Map<DateRangeQueryField, RelativeDateRangeQuery> dates;

  const ParsedFulltextQuery(this.queryText, [this.dates = const {}]);
}

final _relativeDate = RegExp(
  r'^(?<field>created|added|modified):\[-(?<n>\d+) (?<unit>day|week|month|year) to now\]$',
);

/// Only decode the formats emitted by this app. Other Paperless expressions
/// stay intact, especially dates used inside phrases, OR or NOT expressions.
ParsedFulltextQuery parseFulltextQuery(String value) {
  final standalone = _parseDates([value]);
  if (standalone != null) return ParsedFulltextQuery(null, standalone);

  final conjuncts = _splitTopLevel(value, ' AND ');
  if (conjuncts != null && conjuncts.length > 1) {
    final unwrapped = conjuncts.map(_unwrap).toList();
    if (unwrapped.every((part) => part != null)) {
      final parts = unwrapped.cast<String>();
      final datesOnly = _parseDates(parts);
      if (datesOnly != null) return ParsedFulltextQuery(null, datesOnly);
      // Generated queries put the complete user expression in the first group.
      final dates = _parseDates(parts.sublist(1));
      if (!_relativeDate.hasMatch(parts.first) && dates != null) {
        return ParsedFulltextQuery(parts.first, dates);
      }
    }
  }

  // Older mobile versions appended date clauses with commas. Consume only a
  // trailing sequence of complete date clauses, keeping all preceding commas.
  final segments = _splitTopLevel(value, ',');
  if (segments != null && segments.length > 1) {
    var dateStart = segments.length;
    while (dateStart > 0 && _relativeDate.hasMatch(segments[dateStart - 1])) {
      dateStart--;
    }
    if (dateStart < segments.length) {
      final prefix = segments.sublist(0, dateStart);
      final dates = _parseDates(segments.sublist(dateStart));
      final containsDateClause = prefix.any(
        (part) => RegExp(r'^(created|added|modified):').hasMatch(part),
      );
      if (dates != null && !containsDateClause) {
        return ParsedFulltextQuery(
          prefix.isEmpty ? null : prefix.join(','),
          dates,
        );
      }
    }
  }
  return ParsedFulltextQuery(value);
}

Map<DateRangeQueryField, RelativeDateRangeQuery>? _parseDates(
  List<String> parts,
) {
  if (parts.isEmpty) return null;
  final dates = <DateRangeQueryField, RelativeDateRangeQuery>{};
  var previousField = -1;
  for (final part in parts) {
    final match = _relativeDate.firstMatch(part);
    if (match == null || match.end != part.length) return null;
    final field = DateRangeQueryField.values.byName(match.namedGroup('field')!);
    final offset = int.tryParse(match.namedGroup('n')!);
    // App-generated dates have unique fields in created/added/modified order.
    if (field.index <= previousField || offset == null) return null;
    previousField = field.index;
    dates[field] = RelativeDateRangeQuery(
      offset,
      DateRangeUnit.values.byName(match.namedGroup('unit')!),
    );
  }
  return dates;
}

String? _unwrap(String value) {
  if (!value.startsWith('(') || !value.endsWith(')')) return null;
  final inner = value.substring(1, value.length - 1);
  return _splitTopLevel(inner, ' AND ') == null ? null : inner;
}

/// Split without interpreting delimiters inside quotes, escapes or groups.
/// Unbalanced input is left to the server rather than partially decoded.
List<String>? _splitTopLevel(String value, String delimiter) {
  final parts = <String>[];
  final brackets = <String>[];
  String? quote;
  var escaped = false;
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final character = value[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character == r'\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (character == quote) quote = null;
      continue;
    }
    // Apostrophes in ordinary words are not phrase delimiters. Single quotes
    // are supported for range bounds, e.g. added:['-1 week' to now].
    if (character == '"' ||
        (character == "'" && brackets.isNotEmpty && brackets.last != '(')) {
      quote = character;
      continue;
    }
    if (character == '(' || character == '[' || character == '{') {
      brackets.add(character);
    } else if (character == ')' || character == ']' || character == '}') {
      if (brackets.isEmpty) return null;
      final opening = brackets.removeLast();
      // Range bounds may mix inclusive brackets and exclusive braces.
      if ((character == ')' && opening != '(') ||
          (character != ')' && opening == '(')) {
        return null;
      }
    } else if (brackets.isEmpty && value.startsWith(delimiter, i)) {
      parts.add(value.substring(start, i));
      i += delimiter.length - 1;
      start = i + 1;
    }
  }
  if (quote != null || escaped || brackets.isNotEmpty) return null;
  parts.add(value.substring(start));
  return parts;
}
