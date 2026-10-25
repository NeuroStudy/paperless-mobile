import 'package:paperless_mobile/api/converters/local_date_time_json_converter.dart';
import 'package:paperless_mobile/api/models/query_parameters/asn_query_parameter.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/api/utils/fulltext_query.dart';
import 'package:paperless_mobile/features/logging/data/logger.dart';

extension FilterRuleToDocumentFilterExtension on SavedViewFilterRule {
  static const _dateTimeConverter = LocalDateTimeJsonConverter();

  DocumentFilter applyToFilter(final DocumentFilter filter) {
    try {
      switch (ruleType) {
        case RuleTypeEnum.titleContains:
          return filter.copyWith(query: TextQuery.title(value));
        case RuleTypeEnum.documentTypeIs:
          return filter.copyWith(
            documentType: value == null
                ? const NotAssignedIdQueryParameter()
                : IncludeIdsQueryParameter(
                    ids: value!.split(',').map(int.parse).toList(),
                  ),
          );
        case RuleTypeEnum.hasDocumentTypeIn:
          return filter.copyWith(
            documentType: IncludeIdsQueryParameter(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.correspondentIs:
          return filter.copyWith(
            correspondent: value == null
                ? const NotAssignedIdQueryParameter()
                : IncludeIdsQueryParameter(ids: [int.parse(value!)]),
          );
        case RuleTypeEnum.storagePathIs:
          return filter.copyWith(
            storagePath: value == null
                ? const NotAssignedIdQueryParameter()
                : IncludeIdsQueryParameter(ids: [int.parse(value!)]),
          );
        case RuleTypeEnum.hasAnyTag:
          return filter.copyWith(
            tags: value == "true"
                ? const AnyAssignedTagsQuery()
                : const NotAssignedTagsQuery(),
          );
        case RuleTypeEnum.hasTag:
          assert(filter.tags is IdsTagsQuery);
          return filter.copyWith(
            tags: switch (filter.tags) {
              IdsTagsQuery(include: var i, exclude: var e) => IdsTagsQuery(
                include: [...i, int.parse(value!)],
                exclude: e,
              ),
              _ => filter.tags,
            },
          );
        case RuleTypeEnum.doesNotHaveTag:
          assert(filter.tags is IdsTagsQuery);
          return filter.copyWith(
            tags: switch (filter.tags) {
              IdsTagsQuery(include: var i, exclude: var e) => IdsTagsQuery(
                include: i,
                exclude: [...e, int.parse(value!)],
              ),
              _ => filter.tags,
            },
          );
        case RuleTypeEnum.createdBefore:
          if (filter.created is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              created: (filter.created as AbsoluteDateRangeQuery).copyWith(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              created: AbsoluteDateRangeQuery(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.createdAfter:
          if (filter.created is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              created: (filter.created as AbsoluteDateRangeQuery).copyWith(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              created: AbsoluteDateRangeQuery(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.addedBefore:
          if (filter.added is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              added: (filter.added as AbsoluteDateRangeQuery).copyWith(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              added: AbsoluteDateRangeQuery(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.addedAfter:
          if (filter.added is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              added: (filter.added as AbsoluteDateRangeQuery).copyWith(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              added: AbsoluteDateRangeQuery(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.modifiedBefore:
          if (filter.modified is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              modified: (filter.modified as AbsoluteDateRangeQuery).copyWith(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              modified: AbsoluteDateRangeQuery(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.modifiedAfter:
          if (filter.modified is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              modified: (filter.modified as AbsoluteDateRangeQuery).copyWith(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              added: AbsoluteDateRangeQuery(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.titleOrContentContains:
          return filter.copyWith(query: TextQuery.titleAndContent(value));
        case RuleTypeEnum.fulltextQuery:
          return _parseFulltextQuery(filter);
        case RuleTypeEnum.asnIs:
          return filter.copyWith(
            archiveSerialNumber: AsnQueryParameter.equals(
              value: int.parse(value!),
            ),
          );
        case RuleTypeEnum.doesNotHaveAsn:
          return filter.copyWith(
            archiveSerialNumber: AsnQueryParameter.empty(),
          );
        case RuleTypeEnum.moreLikeThis:
          return filter.copyWith(moreLike: int.parse(value!));
        case RuleTypeEnum.hasTagsIn:
          return filter.copyWith(
            tags: IdsTagsQuery(
              include: value!.split(',').map(int.parse).toList(),
              exclude: switch (filter.tags) {
                IdsTagsQuery(exclude: var e) => e,
                _ => [],
              },
            ),
          );
        case RuleTypeEnum.asnGreaterThan:
          return filter.copyWith(
            archiveSerialNumber: AsnQueryParameter.greaterThan(
              value: int.parse(value!),
            ),
          );
        case RuleTypeEnum.asnLessThan:
          return filter.copyWith(
            archiveSerialNumber: AsnQueryParameter.lessThan(
              value: int.parse(value!),
            ),
          );
        case RuleTypeEnum.hasCorrespondentIn:
          return filter.copyWith(
            correspondent: IncludeIdsQueryParameter(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.doesNotHaveCorrespondentIn:
          return filter.copyWith(
            correspondent: IdQueryParameter.exclude(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.doesNotHaveDocumentTypeIn:
          return filter.copyWith(
            documentType: IdQueryParameter.exclude(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.hasStoragePathIn:
          return filter.copyWith(
            storagePath: IdQueryParameter.include(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.doesNotHaveStoragePathIn:
          return filter.copyWith(
            storagePath: IdQueryParameter.exclude(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.ownerIs:
          return filter.copyWith(
            owner: IdQueryParameter.single(id: int.parse(value!)),
          );
        case RuleTypeEnum.hasOwnerIn:
          return filter.copyWith(
            owner: IncludeIdsQueryParameter(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.doesNotHaveOwner:
          return filter.copyWith(owner: const NotAssignedIdQueryParameter());
        case RuleTypeEnum.doesNotHaveOwnerIn:
          return filter.copyWith(
            owner: IdQueryParameter.exclude(
              ids: value!.split(',').map(int.parse).toList(),
            ),
          );
        case RuleTypeEnum.createdTo:
          if (filter.created is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              created: (filter.created as AbsoluteDateRangeQuery).copyWith(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              created: AbsoluteDateRangeQuery(
                before: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        case RuleTypeEnum.createdFrom:
          if (filter.created is AbsoluteDateRangeQuery) {
            return filter.copyWith(
              created: (filter.created as AbsoluteDateRangeQuery).copyWith(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          } else {
            return filter.copyWith(
              created: AbsoluteDateRangeQuery(
                after: _dateTimeConverter.fromJson(value!),
              ),
            );
          }
        default:
          logger.fw(
            'Unsupported filter rule: ${ruleType.name} (#${ruleType.value})',
            className: runtimeType.toString(),
            methodName: 'applyToFilter',
          );
          return filter;
      }
    } catch (e) {
      logger.fe(
        'Error applying filter rule $ruleType with value $value: $e',
        className: runtimeType.toString(),
        methodName: 'applyToFilter',
      );
      return filter;
    }
  }

  DocumentFilter _parseFulltextQuery(DocumentFilter filter) {
    if (value == null) return filter;
    final parsed = parseFulltextQuery(value!);
    return filter.copyWith(
      query: TextQuery.extended(parsed.queryText ?? filter.query.queryText),
      created: parsed.dates[DateRangeQueryField.created] ?? filter.created,
      added: parsed.dates[DateRangeQueryField.added] ?? filter.added,
      modified: parsed.dates[DateRangeQueryField.modified] ?? filter.modified,
    );
  }
}

extension ToFilterRuleExtension on DocumentFilter {
  ///
  /// Converts a [DocumentFilter] to a list of [FilterRule]s.
  ///
  List<SavedViewFilterRule> toFilterRules() {
    List<SavedViewFilterRule> filterRules = [];
    final corrRule = switch (correspondent) {
      NotAssignedIdQueryParameter() => SavedViewFilterRule(
        ruleType: RuleTypeEnum.correspondentIs,
        value: null,
      ),
      IncludeIdsQueryParameter(ids: var ids) => SavedViewFilterRule(
        ruleType: RuleTypeEnum.hasCorrespondentIn,
        value: ids.toString(),
      ),
      AnyAssignedIdQueryParameter() => SavedViewFilterRule(
        ruleType: RuleTypeEnum.correspondentIs,
        value: '-1',
      ),
      ExcludeIdsQueryParameter(ids: var ids) => SavedViewFilterRule(
        ruleType: RuleTypeEnum.doesNotHaveCorrespondentIn,
        value: ids.join(','),
      ),
      _ => null,
    };
    if (corrRule != null) {
      filterRules.add(corrRule);
    }

    final docTypeRule = switch (documentType) {
      NotAssignedIdQueryParameter() => SavedViewFilterRule(
        ruleType: RuleTypeEnum.documentTypeIs,
        value: null,
      ),
      IncludeIdsQueryParameter(ids: var ids) => SavedViewFilterRule(
        ruleType: RuleTypeEnum.hasDocumentTypeIn,
        value: ids.join(','),
      ),
      AnyAssignedIdQueryParameter() => SavedViewFilterRule(
        ruleType: RuleTypeEnum.documentTypeIs,
        value: '-1',
      ),
      ExcludeIdsQueryParameter(ids: var ids) => SavedViewFilterRule(
        ruleType: RuleTypeEnum.doesNotHaveDocumentTypeIn,
        value: ids.join(','),
      ),
      _ => null,
    };

    if (docTypeRule != null) {
      filterRules.add(docTypeRule);
    }

    final sPathRule = switch (storagePath) {
      NotAssignedIdQueryParameter() => SavedViewFilterRule(
        ruleType: RuleTypeEnum.storagePathIs,
        value: null,
      ),
      IncludeIdsQueryParameter(ids: var ids) => SavedViewFilterRule(
        ruleType: RuleTypeEnum.hasStoragePathIn,
        value: ids.join(','),
      ),
      AnyAssignedIdQueryParameter() => SavedViewFilterRule(
        ruleType: RuleTypeEnum.storagePathIs,
        value: '-1',
      ),
      ExcludeIdsQueryParameter(ids: var ids) => SavedViewFilterRule(
        ruleType: RuleTypeEnum.doesNotHaveStoragePathIn,
        value: ids.join(','),
      ),
      _ => null,
    };

    if (sPathRule != null) {
      filterRules.add(sPathRule);
    }
    final tagRules = switch (tags) {
      NotAssignedTagsQuery() => [
        SavedViewFilterRule(ruleType: RuleTypeEnum.hasAnyTag, value: 'false'),
      ],
      AnyAssignedTagsQuery() => [
        SavedViewFilterRule(ruleType: RuleTypeEnum.hasAnyTag, value: 'true'),
      ],
      IdsTagsQuery(include: var include, exclude: var exclude) => [
        ...include.map(
          (id) => SavedViewFilterRule(
            ruleType: RuleTypeEnum.hasTag,
            value: id.toString(),
          ),
        ),
        ...exclude.map(
          (id) => SavedViewFilterRule(
            ruleType: RuleTypeEnum.doesNotHaveTag,
            value: id.toString(),
          ),
        ),
      ],
    };

    filterRules.addAll(tagRules);

    if (query.queryText != null) {
      switch (query.queryType) {
        case QueryType.title:
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.titleContains,
              value: query.queryText!,
            ),
          );
          break;
        case QueryType.titleAndContent:
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.titleOrContentContains,
              value: query.queryText!,
            ),
          );
          break;
        case QueryType.extended:
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.fulltextQuery,
              value: query.queryText!,
            ),
          );
          break;
        case QueryType.asn:
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.asnIs,
              value: query.queryText!,
            ),
          );
          break;
      }

      if (archiveSerialNumber != null) {
        switch (archiveSerialNumber!) {
          case EqualsAsnQueryParameter(value: var value):
            filterRules.add(
              SavedViewFilterRule(
                ruleType: RuleTypeEnum.asnIs,
                value: value.toString(),
              ),
            );
            break;
          case EmptyAsnQueryParameter():
            filterRules.add(
              SavedViewFilterRule(
                ruleType: RuleTypeEnum.doesNotHaveAsn,
                value: 'true',
              ),
            );
            break;
          case NotEmptyAsnQueryParameter():
            filterRules.add(
              SavedViewFilterRule(
                ruleType: RuleTypeEnum.doesNotHaveAsn,
                value: 'false',
              ),
            );
            break;
          case GreaterThanAsnQueryParameter(value: var value):
            filterRules.add(
              SavedViewFilterRule(
                ruleType: RuleTypeEnum.asnGreaterThan,
                value: value.toString(),
              ),
            );
            break;
          case LessThanAsnQueryParameter(value: var value):
            filterRules.add(
              SavedViewFilterRule(
                ruleType: RuleTypeEnum.asnLessThan,
                value: value.toString(),
              ),
            );
            break;
        }
      }
    }

    // Parse created at
    switch (created) {
      case AbsoluteDateRangeQuery(after: var after, before: var before):
        if (after != null) {
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.createdAfter,
              value: apiDateFormat.format(after),
            ),
          );
        }
        if (before != null) {
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.createdBefore,
              value: apiDateFormat.format(before),
            ),
          );
        }
        break;
      case RelativeDateRangeQuery():
        filterRules.add(
          SavedViewFilterRule(
            ruleType: RuleTypeEnum.fulltextQuery,
            value: created
                .toQueryParameter(DateRangeQueryField.created)
                .values
                .first,
          ),
        );
        break;
      default:
        break;
    }

    // Parse added at
    switch (added) {
      case AbsoluteDateRangeQuery(after: var after, before: var before):
        if (after != null) {
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.addedAfter,
              value: apiDateFormat.format(after),
            ),
          );
        }
        if (before != null) {
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.addedBefore,
              value: apiDateFormat.format(before),
            ),
          );
        }
        break;
      case RelativeDateRangeQuery():
        filterRules.add(
          SavedViewFilterRule(
            ruleType: RuleTypeEnum.fulltextQuery,
            value: added
                .toQueryParameter(DateRangeQueryField.added)
                .values
                .first,
          ),
        );
        break;
      default:
        break;
    }

    // Parse modified at
    switch (modified) {
      case AbsoluteDateRangeQuery(after: var after, before: var before):
        if (after != null) {
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.modifiedAfter,
              value: apiDateFormat.format(after),
            ),
          );
        }
        if (before != null) {
          filterRules.add(
            SavedViewFilterRule(
              ruleType: RuleTypeEnum.modifiedBefore,
              value: apiDateFormat.format(before),
            ),
          );
        }
        break;
      case RelativeDateRangeQuery():
        filterRules.add(
          SavedViewFilterRule(
            ruleType: RuleTypeEnum.fulltextQuery,
            value: modified
                .toQueryParameter(DateRangeQueryField.modified)
                .values
                .first,
          ),
        );
        break;
      default:
        break;
    }

    // A full-text rule is one Paperless expression, including relative dates.
    if (filterRules
        .where((e) => e.ruleType == RuleTypeEnum.fulltextQuery)
        .isNotEmpty) {
      final mergedFulltextQueryRule = composeFulltextQuery(
        filterRules
            .where((r) => r.ruleType == RuleTypeEnum.fulltextQuery)
            .map((e) => e.value!),
      );
      filterRules
        ..removeWhere(
          (element) => element.ruleType == RuleTypeEnum.fulltextQuery,
        )
        ..add(
          SavedViewFilterRule(
            ruleType: RuleTypeEnum.fulltextQuery,
            value: mergedFulltextQueryRule,
          ),
        );
    }
    return filterRules;
  }
}

extension FilterRuleToRequest on List<SavedViewFilterRule> {
  List<SavedViewFilterRuleRequest> toRequest() {
    return map(
      (rule) => SavedViewFilterRuleRequest(
        ruleType: rule.ruleType,
        value: rule.value,
      ),
    ).toList();
  }
}
