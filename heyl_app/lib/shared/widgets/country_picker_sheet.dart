import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/country.dart';
import '../../data/repositories/country_repository.dart';
import '../utils/bottom_sheet_utils.dart';
import 'bottom_sheet/ds_sheet_shell.dart';
import 'soko_text_field.dart';

/// Searchable bottom sheet for selecting a phone-number country. DS chrome —
/// wrapped in [DSSheetShell] with a [SokoTextField] search and Soko
/// typography to match the rest of the app's sheets (PROD-2161).
class CountryPickerSheet extends StatefulWidget {
  final Country? selectedCountry;
  final ValueChanged<Country> onCountrySelected;

  const CountryPickerSheet({
    super.key,
    this.selectedCountry,
    required this.onCountrySelected,
  });

  @override
  State<CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<CountryPickerSheet> {
  final _searchController = TextEditingController();
  List<Country> _filteredPopular = CountryRepository.popularCountries;
  List<Country> _filteredAll = CountryRepository.allCountries;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final result = CountryRepository.searchSectioned(_searchController.text);
    setState(() {
      _filteredPopular = result.popular;
      _filteredAll = result.all;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DSSheetShell(
      maxHeightFraction: 0.85,
      header: _Header(
        title: 'Select country',
        onClose: () => Navigator.of(context).pop(),
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: SokoTextField(
              controller: _searchController,
              hintText: 'Search countries',
              autofocus: true,
              prefix: const Icon(
                Icons.search_rounded,
                size: 18,
                color: AppColors.sokoShade3,
              ),
              suffix: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear_rounded,
                        size: 18,
                        color: AppColors.sokoShade3,
                      ),
                      onPressed: _searchController.clear,
                    )
                  : null,
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (_filteredPopular.isNotEmpty) ...[
                  const _SectionHeader('Popular'),
                  ..._filteredPopular.map(
                    (country) => _CountryTile(
                      country: country,
                      isSelected: country == widget.selectedCountry,
                      onTap: () {
                        widget.onCountrySelected(country);
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ],
                if (_filteredAll.isNotEmpty) ...[
                  const _SectionHeader('All countries'),
                  ..._filteredAll.map(
                    (country) => _CountryTile(
                      country: country,
                      isSelected: country == widget.selectedCountry,
                      onTap: () {
                        widget.onCountrySelected(country);
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onClose;
  const _Header({required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              height: 1.2,
              letterSpacing: -0.36,
              color: AppColors.sokoInk,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, color: AppColors.sokoInk),
          onPressed: onClose,
          tooltip: MaterialLocalizations.of(context).closeButtonLabel,
        ),
      ],
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: AppColors.sokoShade3,
        ),
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  final Country country;
  final bool isSelected;
  final VoidCallback onTap;

  const _CountryTile({
    required this.country,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
      leading: Text(country.flag, style: const TextStyle(fontSize: 24)),
      title: Text(
        country.name,
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: AppColors.sokoInk,
        ),
      ),
      subtitle: Text(
        country.dialCode,
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 13,
          color: AppColors.sokoShade3,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check_rounded, color: AppColors.sokoInk)
          : null,
    );
  }
}

/// Shows the country picker bottom sheet. Routes through the canonical
/// [showBottomSheetWithHiddenNav] so the bottom nav hides while open (no-op
/// on AuthShell, relevant on `/menu/account`) and the sheet picks up the
/// Soko branded scrim + root-Overlay mounting.
void showCountryPickerSheet(
  BuildContext context, {
  required WidgetRef ref,
  Country? selectedCountry,
  required ValueChanged<Country> onCountrySelected,
}) {
  // Dismiss keyboard before opening sheet.
  FocusScope.of(context).unfocus();

  showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => CountryPickerSheet(
      selectedCountry: selectedCountry,
      onCountrySelected: onCountrySelected,
    ),
  );
}
