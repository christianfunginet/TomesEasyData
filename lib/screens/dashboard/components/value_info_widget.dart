import 'package:tomesdashboard/models/my_files.dart';
import 'package:tomesdashboard/responsive.dart';
import 'package:flutter/material.dart';

import '../../../constants.dart';
import 'value_info_card.dart';

class ValueInfoWidget extends StatelessWidget {
  final List<SingleValueInfo> infoValues;
  final List<String> equipos;
  final Function(String)? onEquipoChanged;
  final String actualSelection;
  const ValueInfoWidget({
    super.key,
    required this.infoValues,
    required this.equipos,
    required this.onEquipoChanged,
    required this.actualSelection,
  });

  @override
  Widget build(BuildContext context) {
    final Size _size = MediaQuery.of(context).size;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "DASHBOARD",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                padding: EdgeInsets.only(right: 12,left: 12),
                icon: const Icon(Icons.arrow_drop_down_circle, color: Colors.blueAccent),
                iconSize: 28,
                borderRadius: BorderRadius.circular(12.0), // 5. Menu borders
              
                value: actualSelection,
                onChanged: (String? newValue) {
                  onEquipoChanged?.call(newValue ?? '');
                },
                items: equipos.map<DropdownMenuItem<String>>((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
              ),
            ),
            
          ],
        ),
        SizedBox(height: defaultPadding),
        Responsive(
          mobile: ValueInfoCardGridView(infoValues: infoValues,
            crossAxisCount: _size.width < 650 ? 2 : 4,
            childAspectRatio: _size.width < 650 && _size.width > 350 ? 1.3 : 1,
          ),
          tablet: ValueInfoCardGridView(infoValues: infoValues),
          desktop: ValueInfoCardGridView(
            infoValues: infoValues,
            childAspectRatio: _size.width < 1400 ? 1.1 : 1.4,
          ),
        ),
      ],
    );
  }
}

class ValueInfoCardGridView extends StatelessWidget {
  final List<SingleValueInfo> infoValues;

  const ValueInfoCardGridView({
    super.key,
    this.crossAxisCount = 4,
    this.childAspectRatio = 1,
    required this.infoValues,
  });

  final int crossAxisCount;
  final double childAspectRatio;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: infoValues.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: defaultPadding,
        mainAxisSpacing: defaultPadding,
        childAspectRatio: childAspectRatio,
      ),
      itemBuilder: (context, index) => ValueInfoCard(info: infoValues[index]),
    );
  }
}
