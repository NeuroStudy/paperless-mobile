import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/features/logging/data/logger.dart';

SavedView _view(String? query) => SavedView(
  id: 1,
  name: 'Test view',
  showOnDashboard: false,
  showInSidebar: true,
  userCanChange: true,
  filterRules: [
    SavedViewFilterRule(ruleType: RuleTypeEnum.fulltextQuery, value: query),
  ],
);

SavedView _save(DocumentFilter filter) => SavedView.fromJson({
  ...filter
      .toSavedViewRequest(
        name: 'Renamed view',
        showInSidebar: false,
        showOnDashboard: true,
      )
      .toJson(),
  'id': 1,
  'user_can_change': true,
});

String? _savedQuery(DocumentFilter filter) => filter
    .toFilterRules()
    .where((rule) => rule.ruleType == RuleTypeEnum.fulltextQuery)
    .singleOrNull
    ?.value;

void main() {
  setUpAll(() => logger = Logger(level: Level.off));

  group('saved advanced queries', () {
    for (final query in [
      'alpha,beta',
      'alpha,beta,gamma',
      '"ACME, Inc."',
      "O'Reilly, Inc.",
      ',alpha,',
      '  alpha, beta  ',
      r'title:"ACME, \"Inc.\""',
      r'alpha\,beta',
      '"created:[-7 day to now],invoice"',
      'invoice OR created:[-7 day to now]',
      'NOT created:[-7 day to now]',
      '(invoice OR created:[-7 day to now])',
      '(invoice) OR (created:[-7 day to now])',
      '(invoice) AND (created:[-7 day to now] OR tag:urgent)',
      'created:[7 day to now]',
      'created:[-7 days to now]',
      'created:[-9999999999999999999999999 day to now]',
      'invoice,created:[-7 day to now],created:[-2 day to now]',
      'created:[-7 day to now],invoice',
      'invoice,modified:[-7 day to now],added:[-2 day to now]',
      'invoice,created:[7 day to now],added:[-2 day to now]',
      '(invoice) AND (created:[-7 day to now]) OR (receipt)',
      '(invoice) AND (created:[-7 day to now]) AND (created:[-2 day to now])',
      '(invoice) AND (modified:[-1 day to now]) AND (added:[-2 day to now])',
      '"unclosed,created:[-7 day to now]',
      '(unclosed,created:[-7 day to now]',
      'invoice\\',
      '',
    ]) {
      test('preserves $query through loading and metadata edits', () {
        final restored = _view(query).toDocumentFilter();
        expect(restored.query, TextQuery.extended(query));
        expect(restored.created, isA<UnsetDateRangeQuery>());
        expect(restored.added, isA<UnsetDateRangeQuery>());
        expect(restored.modified, isA<UnsetDateRangeQuery>());
        final edited = _save(restored);
        expect(edited.name, 'Renamed view');
        expect(edited.showInSidebar, isFalse);
        expect(edited.showOnDashboard, isTrue);
        expect(edited.filterRules.single.value, query);
        expect(edited.toDocumentFilter().query.queryText, query);
        expect(
          restored.toQueryParameters()['query'],
          query.isEmpty ? null : query,
        );
      });
    }

    test('ignores a null fulltext value without losing existing filters', () {
      final filter = DocumentFilter(
        query: const TextQuery.extended('alpha,beta'),
        created: const RelativeDateRangeQuery(2, DateRangeUnit.week),
      );
      expect(_view(null).filterRules.single.applyToFilter(filter), filter);
    });
  });

  group('canonical query composition', () {
    test(
      'no query or dates produces no fulltext rule or request parameter',
      () {
        expect(_savedQuery(const DocumentFilter()), isNull);
        expect(
          const DocumentFilter().toQueryParameters(),
          isNot(contains('query')),
        );
      },
    );

    for (final query in <String?>[
      null,
      '"ACME, Inc." OR invoice',
      "O'Reilly, Inc.",
      ' alpha,beta ',
      r'title:"ACME, \"Inc.\""',
      '(invoice OR receipt) AND NOT draft',
      '"created:[-7 day to now],invoice"',
      "added:['-1 week' to now]",
      'created:{2005 to 2009]',
    ]) {
      for (final fields in [
        [DateRangeQueryField.created],
        [DateRangeQueryField.added],
        [DateRangeQueryField.modified],
        DateRangeQueryField.values,
      ]) {
        test('round trips $query with $fields', () {
          const date = RelativeDateRangeQuery(7, DateRangeUnit.day);
          final filter = DocumentFilter(
            query: TextQuery.extended(query),
            created: fields.contains(DateRangeQueryField.created)
                ? date
                : const UnsetDateRangeQuery(),
            added: fields.contains(DateRangeQueryField.added)
                ? date
                : const UnsetDateRangeQuery(),
            modified: fields.contains(DateRangeQueryField.modified)
                ? date
                : const UnsetDateRangeQuery(),
          );
          final components = [
            ?query,
            ...fields.map((field) => '${field.name}:[-7 day to now]'),
          ];
          final expected = components.length == 1
              ? components.single
              : components.map((part) => '($part)').join(' AND ');
          expect(_savedQuery(filter), expected);
          expect(filter.toQueryParameters()['query'], expected);
          final restored = _save(filter).toDocumentFilter();
          expect(restored.query, filter.query);
          for (final field in fields) {
            final restoredDate = switch (field) {
              DateRangeQueryField.created => restored.created,
              DateRangeQueryField.added => restored.added,
              DateRangeQueryField.modified => restored.modified,
            };
            expect(restoredDate, date);
          }
          expect(_savedQuery(restored), expected);
          expect(_savedQuery(_save(restored).toDocumentFilter()), expected);
          expect(restored.toQueryParameters()['query'], expected);
        });
      }
    }
  });

  group('legacy relative date queries', () {
    for (final prefix in <String?>[
      null,
      'alpha,beta,gamma',
      '"ACME, Inc."',
      "O'Reilly, Inc.",
      r'title:"ACME, \"Inc.\""',
      r'alpha\,beta',
      '(invoice OR receipt)',
      '"added:[-5 day to now],modified:[-1 year to now]"',
    ]) {
      test('restores dates without losing $prefix', () {
        final legacy = [
          ?prefix,
          'created:[-7 day to now]',
          'added:[-2 week to now]',
          'modified:[-1 year to now]',
        ].join(',');
        final restored = _view(legacy).toDocumentFilter();
        expect(restored.query, TextQuery.extended(prefix));
        expect(restored.created, const RelativeDateRangeQuery(7));
        expect(
          restored.added,
          const RelativeDateRangeQuery(2, DateRangeUnit.week),
        );
        expect(
          restored.modified,
          const RelativeDateRangeQuery(1, DateRangeUnit.year),
        );
        final expected = [
          if (prefix != null) '($prefix)',
          '(created:[-7 day to now])',
          '(added:[-2 week to now])',
          '(modified:[-1 year to now])',
        ].join(' AND ');
        expect(_savedQuery(restored), expected);
        expect(restored.toQueryParameters()['query'], expected);
        expect(_savedQuery(_save(restored).toDocumentFilter()), expected);
      });
    }
  });

  test('leaves absolute dates and comma-separated parameters unchanged', () {
    final filter = DocumentFilter(
      query: const TextQuery.extended('alpha,beta'),
      created: AbsoluteDateRangeQuery(
        after: DateTime(2024, 1, 1),
        before: DateTime(2024, 1, 31),
      ),
      documentType: const IncludeIdsQueryParameter(ids: [1, 2]),
      tags: const IdsTagsQuery(include: [3, 4]),
      documentIds: [5, 6],
      fields: ['id', 'title'],
    );
    final params = filter.toQueryParameters();
    expect(params['query'], 'alpha,beta');
    expect(params['created__date__gt'], '2023-12-31');
    expect(params['created__date__lt'], '2024-02-01');
    expect(params['document_type__id__in'], '1,2');
    expect(params['tags__id__all'], '3,4');
    expect(params['id__in'], '5,6');
    expect(params['fields'], 'id,title');
    final restored = _save(filter).toDocumentFilter();
    expect(restored.created, filter.created);
    expect(restored.documentType, filter.documentType);
    expect(restored.tags, filter.tags);
  });
}
