import 'package:tomesdashboard/responsive.dart';
import 'package:flutter/material.dart';
import 'package:tomesdashboard/screens/dashboard/components/chart_info_widget.dart';

import 'constants.dart';
import 'screens/dashboard/components/header.dart';



class ChartPage extends StatelessWidget {
  const ChartPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.all(defaultPadding),
        child: Column(
          children: [
            SizedBox(height: defaultPadding),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      ChartInfoWidget(infoValues: [], equipos: [], onEquipoChanged: (String p1) {  }, actualSelection: '',),
                      SizedBox(height: defaultPadding),
                     // RecentFiles(),
                      if (Responsive.isMobile(context))
                        SizedBox(height: defaultPadding),
                      if (Responsive.isMobile(context))SizedBox(),// StorageDetails(),
                    ],
                  ),
                ),
                if (!Responsive.isMobile(context))
                  SizedBox(width: defaultPadding),
                // On Mobile means if the screen is less than 850 we don't want to show it
                if (!Responsive.isMobile(context))
                  Expanded(
                    flex: 2,
                    child:SizedBox(
                      height: 200,
                      // StorageDetails(),
                    ),
                  ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
