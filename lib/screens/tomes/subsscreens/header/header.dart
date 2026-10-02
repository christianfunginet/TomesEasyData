import 'package:tomesdashboard/responsive.dart';
import 'package:flutter/material.dart';

import '../../../../constants.dart';

class Header extends StatelessWidget {
  final List<String> equipos;
  final Function(String)? onEquipoChanged;
  final String actualSelection;

  const Header({
    required this.equipos,
    required this.onEquipoChanged,
    required this.actualSelection,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (!Responsive.isDesktop(context))
          IconButton(
            icon: Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        if (!Responsive.isMobile(context))
          Text(
            "Dashboard",
            style: Theme.of(context).textTheme.titleLarge,
          ),
        if (!Responsive.isMobile(context))
          Spacer(flex: Responsive.isDesktop(context) ? 2 : 1),
        Expanded(child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                padding: EdgeInsets.only(right: 12,left: 12),
                icon: Icon(Icons.arrow_drop_down_circle, color:  Theme.of(context).primaryColor, ),
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
            )
           ),
//        ProfileCard()
      ],
    );
  }
}

class ProfileCard extends StatelessWidget {
  const ProfileCard({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(left: defaultPadding),
      padding: EdgeInsets.symmetric(
        horizontal: defaultPadding,
        vertical: defaultPadding / 2,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Image.asset(
            "assets/images/profile_pic.png",
            height: 38,
          ),
          if (!Responsive.isMobile(context))
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: defaultPadding / 2),
              child: Text("Angelina Jolie"),
            ),
          Icon(Icons.keyboard_arrow_down),
        ],
      ),
    );
  }
}

