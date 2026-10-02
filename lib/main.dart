import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tabbed_view/tabbed_view.dart';
import 'package:tomesdashboard/screens/dloganalyzer/dlog_decoder/dlog_home_page.dart';
import 'package:tomesdashboard/screens/dloganalyzer/grapic_page.dart';
import 'package:tomesdashboard/screens/tomes/main_screen.dart';
import 'package:tomesdashboard/app_preferences.dart';
//import 'package:universal_io/io.dart';
// ignore: depend_on_referenced_packages

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final savedThemeMode = await AppPreferences.getThemeMode();

  runApp(MyApp(initialThemeMode: savedThemeMode));
}

final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class MyApp extends StatelessWidget {
  MyApp({
    super.key,
    required ThemeMode initialThemeMode,
  }) : _notifier = ValueNotifier<ThemeMode>(initialThemeMode);

  final ValueNotifier<ThemeMode> _notifier;
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _notifier,
      builder: (_, mode, _) {
        return MaterialApp(
          title: 'Terumo Tool Set',
          scrollBehavior: MyCustomScrollBehavior(),
          scaffoldMessengerKey: _scaffoldMessengerKey,
          debugShowCheckedModeBanner: false,
          darkTheme: ThemeData.dark().copyWith(primaryColor: const Color.fromARGB(255, 79, 203, 7) ),
          themeMode: mode,
          theme: ThemeData.light().copyWith(primaryColor: const Color.fromARGB(255, 51, 114, 14)),
          home: MyHomePage(title: 'Terumo Tool Set', notifier: _notifier),
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
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Flexible(
                  flex: 65,
                  child: Text("With the dLogs analysis tool, you can upload a CSV file obtained via the STS RAT, plot the signals of your choice, and zoom in or pan the graphs in any direction. You can also review the event log and locate the exact moment you are looking for.",
                  style: TextStyle(fontSize: 22),
                  ),
                ),
                SizedBox(width: 30,),
                Flexible(
                  flex: 35,
                   child: Container(
                    width: 150,
                    height: 220,
                    decoration: BoxDecoration(  
                      image: DecorationImage(image:  AssetImage("assets/images/img1.jpg",),fit: BoxFit.cover)  ,
                      //color: Theme.of(context).splashColor,
                    borderRadius: BorderRadius.only (bottomLeft:  Radius.circular(12),bottomRight:  Radius.circular(12)),
                    ),
                  ),
                ),
           

              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Flexible(
                  flex: 35,
                   child: Container(
                    width: 150,
                    height: 220,
                    decoration: BoxDecoration(  
                      image: DecorationImage(image:  AssetImage("assets/images/img2.jpg",),fit: BoxFit.cover)  ,
                      //color: Theme.of(context).splashColor,
                    borderRadius: BorderRadius.only (bottomLeft:  Radius.circular(12),bottomRight:  Radius.circular(12)),
                    ),
                  ),
                ),
              SizedBox(width: 30,),
               Flexible(
                  flex: 65,
                  child: Text("Using the time analysis tool, you can upload a block of data logs directly and determine the incidence of failures—both in terms of quality and quantity—thereby formulating the best action plan for each piece of equipment studied.",
                  style: TextStyle(fontSize: 22),
                  ),
                ),
            

              ],
            )

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
  void addAnalyzePage(
    String? path,
    String fileName,
    Uint8List? bytes,
  ) {
    _controller.addTab(
      TabData(
        text: fileName,
        content: _DeferredGraphicPage(
          filePath: path,
          fileName: fileName,
          fileBytes: bytes,
        ),
        keepAlive: true,
      ),
    );
    _controller.selectTab(_controller.tabs.last);
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
                if (Theme.of(context).brightness == Brightness.light) {
                  _brightness = Brightness.dark;
                  widget.notifier.value = ThemeMode.dark;
                  AppPreferences.setThemeMode(ThemeMode.dark);
                } else {
                  _brightness = Brightness.light;
                  widget.notifier.value = ThemeMode.light;
                  AppPreferences.setThemeMode(ThemeMode.light);
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
        backgroundColor: Theme.of(context).primaryColor,
        tooltip: 'Add file',
        onPressed: () async {
          final result = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['dlog', 'csv'],
            withData: true,
            allowMultiple: true,
          );
          if (result == null || result.files.isEmpty) return;

          final dlogFiles = result.files
              .where((f) => f.extension?.toLowerCase() == 'dlog')
              .toList();
          final csvFiles = result.files
              .where((f) => f.extension?.toLowerCase() == 'csv')
              .toList();

          if (dlogFiles.length == 1) {
            final file = dlogFiles.first;
            addAnalyzePage(file.path, file.name, file.bytes);
          } else if (dlogFiles.length > 1) {
            final dlogResult = FilePickerResult(dlogFiles);
            _controller.addTab(
              TabData(
                text: dlogFiles.first.name.split('_').first,
                content: DlogHomePage(
                  files: dlogResult,
                  onAnalyzeRequest: addAnalyzePage,
                ),
                keepAlive: true,
              ),
            );
            _controller.selectTab(_controller.tabs.last);
          }

          // CSV conserva el comportamiento anterior.
          for (final pickFile in csvFiles) {
            final name = pickFile.name;
            if (name.contains('1W') ||
                name.contains('1P') ||
                name.contains('1T')) {
              _controller.addTab(
                TabData(
                  text: pickFile.name,
                  content: _DeferredGraphicPage(
                    filePath: pickFile.path,
                    fileName: pickFile.name,
                    fileBytes: pickFile.bytes,
                  ),
                  keepAlive: true,
                ),
              );
              _controller.selectTab(_controller.tabs.last);
            } else {
              _controller.addTab(
                TabData(
                  text: pickFile.name,
                  content: MainScreen(
                    file: pickFile,
                    title: 'Tomes Easy Data',
                  ),
                  keepAlive: true,
                ),
              );
              _controller.selectTab(_controller.tabs.last);
            }
          }

          if (_controller.tabs.isNotEmpty &&
              _controller.tabs.first.text == 'INIT') {
            _controller.removeTab(0);
          }
        },
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
       onDraggableBuild: (controller, tabIndex, tab) {
         return DraggableConfig(canDrag: true, feedback: null, feedbackOffset: Offset.zero, dragAnchorStrategy: childDragAnchorStrategy, onDragStarted: null, onDragUpdate: null, onDraggableCanceled: null, onDragEnd: null, onDragCompleted: null);
      },
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


class _DeferredGraphicPage extends StatefulWidget {
  const _DeferredGraphicPage({
    required this.filePath,
    required this.fileName,
    required this.fileBytes,
  });

  final String? filePath;
  final String fileName;
  final Uint8List? fileBytes;

  @override
  State<_DeferredGraphicPage> createState() => _DeferredGraphicPageState();
}

class _DeferredGraphicPageState extends State<_DeferredGraphicPage> {
  bool _showGraphic = false;

  @override
  void initState() {
    super.initState();
    _openAfterFirstPaint();
  }

  Future<void> _openAfterFirstPaint() async {
    // First show the selected tab and its loading UI.
    await WidgetsBinding.instance.endOfFrame;

    // Give the tab view one additional frame before GraphicPage starts
    // parsing/decoding the selected file.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    if (!mounted) return;
    setState(() => _showGraphic = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_showGraphic) {
      return GraphicPage(
        filePath: widget.filePath,
        fileName: widget.fileName,
        fileBytes: widget.fileBytes,
        title: 'Dlog Analyzer',
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 28,
              vertical: 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Opening DLOG…',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Preparing Graphic Page',
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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