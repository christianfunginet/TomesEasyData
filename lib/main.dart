import 'dart:ui';

import 'package:tomesdashboard/dashboard_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:tabbed_view/tabbed_view.dart';
import 'package:tomesdashboard/screens/main/main_screen.dart';
import 'package:universal_io/io.dart';
// ignore: depend_on_referenced_packages

void main() {
  runApp(MyApp());
}

final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class MyApp extends StatelessWidget {
  MyApp({super.key});
  final ValueNotifier<ThemeMode> _notifier = ValueNotifier(ThemeMode.system);
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _notifier,
      builder: (_, mode, _) {
        return MaterialApp(
          title: 'Tomes Easy Data',
          scrollBehavior: MyCustomScrollBehavior(),

          scaffoldMessengerKey: _scaffoldMessengerKey,
          debugShowCheckedModeBanner: false,
          darkTheme: ThemeData.dark().copyWith(primaryColor: const Color.fromARGB(255, 174, 255, 127)),
          themeMode: mode,
          theme: ThemeData.light().copyWith(primaryColor: const Color.fromARGB(255, 95, 167, 53)),
          home: MyHomePage(title: 'Tomes Easy Data', notifier: _notifier),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  final ValueNotifier<ThemeMode> notifier;
  const MyHomePage({super.key, required this.title, required this.notifier});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  List<File> files = [];
  final GlobalKey<ScaffoldMessengerState> _sk = GlobalKey<ScaffoldMessengerState>();

  late TabbedViewController _controller;
  final TabBarPosition _position = TabBarPosition.bottom;
  final ThemeName _themeName = ThemeName.minimalist;
  final SideTabsLayout _sideTabsLayout = SideTabsLayout.rotated;
  final bool _modifyThemeColors = false;
  final bool _maxMainSizeEnabled = false;
  final bool _trailingWidgetEnabled = false;
  final bool _addButtonEnabled = true;
  Brightness _brightness = Brightness.dark;
  List<TabData> tabs = [];
  late TabData initTab;
  @override
  void initState() {
    super.initState();
    initTab = TabData(
      text: 'INIT',
      leading: (context, status) => Icon(Icons.star, size: 16),
      content: Padding(
        padding: EdgeInsets.all(8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Stack(
              alignment: AlignmentGeometry.bottomCenter,
              children: [
                Container(
                  width: 350,
                  height: 350 * 1.3,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    image: DecorationImage(fit: BoxFit.cover, image: AssetImage("assets/images/img1.jpg")),
                  ),
                ),
                Container(
                  width: 350,
                  height: 100,
                  decoration: BoxDecoration(color: const Color.fromARGB(255, 73, 73, 73), 
                  borderRadius: BorderRadius.only (bottomLeft:  Radius.circular(12),bottomRight:  Radius.circular(12)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text("Ability to graph multiple variables and analyze the exact moment of each alarm. Selection of detailed areas for visualizing specific events.", 
                      style: TextStyle(color: const Color.fromARGB(255, 223, 222, 222)),
                    overflow: TextOverflow.clip),
                  ),
                ),
              ],
            ),
            Stack(
              alignment: AlignmentGeometry.bottomCenter,
              children: [
                Container(
                  width: 350,
                  height: 350 * 1.3,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    image: DecorationImage(fit: BoxFit.cover, image: AssetImage("assets/images/img2.jpg")),
                  ),
                ),
                Container(
                  width: 350,
                  height: 100,
                  decoration: BoxDecoration(color: const Color.fromARGB(255, 73, 73, 73), 
                  borderRadius: BorderRadius.only (bottomLeft:  Radius.circular(12),bottomRight:  Radius.circular(12)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text("Zoom and Pan functions along with the ability to easily select or deselect parameters.", 
                      style: TextStyle(color: const Color.fromARGB(255, 223, 222, 222)),
                    overflow: TextOverflow.clip),
                  ),
                ),
              ],
            ),
            Stack(
              alignment: AlignmentGeometry.bottomCenter,
              children: [
                Container(
                  width: 350,
                  height: 350 * 1.3,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    image: DecorationImage(fit: BoxFit.cover, image: AssetImage("assets/images/img3.jpg")),
                  ),
                ),
                Container(
                  width: 350,
                  height: 100,
                  decoration: BoxDecoration(color: const Color.fromARGB(255, 73, 73, 73), 
                  borderRadius: BorderRadius.only (bottomLeft:  Radius.circular(12),bottomRight:  Radius.circular(12)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text("Detailed analysis of episodic events for easier fault detection.", 
                      style: TextStyle(color: const Color.fromARGB(255, 223, 222, 222)),
                    overflow: TextOverflow.clip),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      buttonsBuilder: (context) => [
        TabButton.icon(
          IconProvider.data(Icons.info),
          onPressed: () {
            _sk.currentState?.showSnackBar(const SnackBar(content: Text('Created by Tech Serv Argentina')));
          },
        ),
      ],
    );
    tabs.add(initTab);
   
    _controller = TabbedViewController(
      tabs,
      onTabReorder: (int oldIndex, int newIndex) {},
      onTabSelection: (index, tabData) {},
      onTabRemove: (tabData) {
        if (tabs.isEmpty) {
          _controller.removeTabs();
          // tabs.add(initTab);
          _controller.addTab(initTab);
          Future.delayed(Duration(milliseconds: 300), () {
            _controller.selectTab(initTab);
          });
          // _controller.selectTab(initTab);
          //  setState(() {});
        }
      },
    );
  }

  TabbedViewThemeData _getTheme() {
    TabbedViewThemeData theme;
    switch (_themeName) {
      case ThemeName.classic:
        theme = _modifyThemeColors ? TabbedViewThemeData.classic(brightness: _brightness, colorSet: Colors.blueGrey, borderColor: Colors.black) : TabbedViewThemeData.classic(brightness: _brightness);
        break;
      case ThemeName.minimalist:
        theme = _modifyThemeColors ? TabbedViewThemeData.minimalist(brightness: _brightness, colorSet: Colors.blueGrey) : TabbedViewThemeData.minimalist(brightness: _brightness);
        break;
      case ThemeName.underline:
        theme = _modifyThemeColors ? TabbedViewThemeData.underline(brightness: _brightness, colorSet: Colors.brown, underlineColorSet: Colors.brown) : TabbedViewThemeData.underline(brightness: _brightness);
        break;
    }
    theme.tabsArea.position = _position;
    theme.tabsArea.sideTabsLayout = _sideTabsLayout;
    if (_maxMainSizeEnabled) {
      theme.tab.maxMainSize = 200;
    }
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _sk,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: Icon(Icons.info),
            onPressed: () {
              showAboutDialog(
                context: context,
                applicationName: widget.title,
                applicationVersion: "1.1",
                children: [Text('Created by Tech Serv Argentina')],
                );
            },
          ),
          IconButton(
            onPressed: () {
              setState(() {
                if (Theme.of(context).brightness  == Brightness.light) {
                  _brightness = Brightness.dark;
                  widget.notifier.value = ThemeMode.dark;
                } else {
                  _brightness = Brightness.light;
                  widget.notifier.value = ThemeMode.light;
                }
              });
            },
            icon: Theme.of(context).brightness == Brightness.light ? Icon(Icons.dark_mode) : Icon(Icons.light_mode),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // _buildSettings(),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: TabbedViewTheme(data: _getTheme(), child: _buildTabbedView()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          FilePickerResult? result = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['csv'],
            withData: true,
            allowMultiple: true,
          );

          if (result != null) {
            for (var pickFile in result.files) {
              
            File file ;
            if (Platform.isWindows) {
               file = File(pickFile.path!);
            }else{
               file = File(pickFile.name);
           
            }
            files.add(file);

            _controller.addTab(
              TabData(
                text: pickFile.name,
                content:MainScreen(file: pickFile, title: ''),
                keepAlive: true,
              ),
            );
            _controller.tabs.first.text == "INIT" ? _controller.removeTab(0) : null;
           }
           
          }
          // _controller = TabbedViewController(tabs, onTabReorder: (int oldIndex, int newIndex) {}, onTabSelection: (index, tabData) {}, onTabRemove: (tabData) {});
          //   setState(() {});
        },
        tooltip: 'Add File',
        child: const Icon(Icons.add),
      ),
    );
  }

  TabbedView _buildTabbedView() {
    // Configuring the [TabbedView] with all available properties.
    return TabbedView(
      trailing: _trailingWidgetEnabled ? Padding(padding: const EdgeInsets.fromLTRB(0, 0, 8, 0), child: Text('Trailing text')) : null,
      controller: _controller,

      onTabSecondaryTap: (index, tabData, details) {
        _sk.currentState?.showSnackBar(SnackBar(content: Text('Right-clicked on tab #$index: "${tabData.text}"')));
      },

      contentBuilder: null,
      tabsAreaButtonsBuilder: _addButtonEnabled
          ? (context, tabsCount) {
              return [
                TabButton.icon(
                  IconProvider.data(Icons.add),
                  onPressed: () {
                    _controller.addTab(
                      TabData(
                        text: 'New Tab',
                        content: Center(child: Text('Content of New Tab')),
                      ),
                    );
                  },
                ),
              ];
            }
          : null,
      // onDraggableBuild: (controller, tabIndex, tab) {
      //   return DraggableConfig(canDrag: true, feedback: null, feedbackOffset: Offset.zero, dragAnchorStrategy: childDragAnchorStrategy, onDragStarted: null, onDragUpdate: null, onDraggableCanceled: null, onDragEnd: null, onDragCompleted: null);
      // },
      tabRemoveInterceptor: (context, index, tabData) {
        if (tabData.text == 'Tab 1') {
          return false;
        }
        return true;
      },
      closeButtonTooltip: 'Close this tab',
      tabsAreaVisible: true,
      contentClip: false,
      dragScope: null,
      unselectedTabButtonsBehavior: UnselectedTabButtonsBehavior.allDisabled,
    );
  }


  

  
  
}

class PositionChooser extends StatelessWidget {
  const PositionChooser({super.key, required this.currentPosition, required this.onSelected});

  final TabBarPosition currentPosition;
  final Function(TabBarPosition newPosition) onSelected;

  @override
  Widget build(BuildContext context) {
    List<Widget> children = TabBarPosition.values.map<Widget>((value) {
      return ChoiceChip(label: Text(value.name), selected: currentPosition == value, onSelected: (selected) => onSelected(value));
    }).toList();

    return Wrap(spacing: 8, runSpacing: 4, children: children);
  }
}

class SideTabsLayoutChooser extends StatelessWidget {
  const SideTabsLayoutChooser({super.key, required this.currentLayout, required this.onSelected, required this.currentPosition});

  final SideTabsLayout currentLayout;
  final TabBarPosition currentPosition;
  final Function(SideTabsLayout newLayout) onSelected;

  @override
  Widget build(BuildContext context) {
    List<Widget> children = SideTabsLayout.values.map<Widget>((value) {
      return ChoiceChip(label: Text(value.name), selected: currentLayout == value, onSelected: currentPosition.isVertical ? (selected) => onSelected(value) : null);
    }).toList();

    return Wrap(spacing: 8, runSpacing: 4, children: children);
  }
}

enum ThemeName { classic, underline, minimalist }

class ThemeChooser extends StatelessWidget {
  const ThemeChooser({super.key, required this.currentTheme, required this.onSelected});

  final ThemeName currentTheme;
  final Function(ThemeName themeName) onSelected;

  @override
  Widget build(BuildContext context) {
    List<Widget> children = ThemeName.values.map<Widget>((value) {
      return ChoiceChip(label: Text(value.name), selected: currentTheme == value, onSelected: (selected) => onSelected(value));
    }).toList();

    return Wrap(spacing: 8, runSpacing: 4, children: children);
  }
}

class BrightnessChooser extends StatelessWidget {
  const BrightnessChooser({super.key, required this.currentBrightness, required this.onSelected});

  final Brightness currentBrightness;
  final Function(Brightness brightness) onSelected;

  @override
  Widget build(BuildContext context) {
    List<Widget> children = Brightness.values.map<Widget>((value) {
      return ChoiceChip(label: Text(value.name), selected: currentBrightness == value, onSelected: (selected) => onSelected(value));
    }).toList();

    return Wrap(spacing: 8, runSpacing: 4, children: children);
  }
}

class TimeSeriesSales {
  final DateTime time;
  final int v1;
  final int v2;

  TimeSeriesSales(this.time, this.v1, this.v2);
}

class MyCustomScrollBehavior extends MaterialScrollBehavior {
  // Override behavior to include both touch and mouse drag devices
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}