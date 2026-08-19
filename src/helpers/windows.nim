#=======================================================
# Arturo
# Programming Language + Bytecode VM compiler
# (c) 2019-2026 Yanis Zafirópulos
#
# @file: helpers/webview.nim
#=======================================================

#=======================================
# Libraries
#=======================================

import tables

import extras/window
import extras/menus

export window, menus

type
    MenuAction* = proc(userData: pointer) {.closure.}

    MenuItemKind* = enum
        NormalItem
        SeparatorItem
        SubmenuItem

    MenuItem* = ref object
        case kind*: MenuItemKind
        of NormalItem:
            label*: string
            shortcut*: string
            enabled*: bool
            checked*: bool
            action*: MenuAction
            userData*: pointer
        of SeparatorItem:
            discard
        of SubmenuItem:
            submenuLabel*: string
            submenu*: Menu

    Menu* = ref object
        title*: string
        items*: seq[MenuItem]

#=======================================
# Methods
#=======================================

proc isMaximized*(w: Window): bool =
    is_maximized_window(w)

proc isMinimized*(w: Window): bool =
    is_minimized_window(w)

proc isVisible*(w: Window): bool =
    is_visible_window(w)

proc isFullscreen*(w: Window): bool =
    is_fullscreen_window(w)

proc getSize*(w: Window): WindowSize =
    get_window_size(w)

proc setSize*(w: Window, sz: WindowSize) =
    set_window_size(w, sz)

proc getMinSize*(w: Window): WindowSize =
    get_window_min_size(w)

proc setMinSize*(w: Window, sz: WindowSize) =
    set_window_min_size(w, sz)

proc getMaxSize*(w: Window): WindowSize =
    get_window_max_size(w)

proc setMaxSize*(w: Window, sz: WindowSize) =
    set_window_max_size(w, sz)

proc getPosition*(w: Window): WindowPosition =
    get_window_position(w)

proc setPosition*(w: Window, pos: WindowPosition) =
    set_window_position(w, pos)

proc center*(w: Window) =
    center_window(w)

proc maximize*(w: Window) =
    if not w.isMaximized():
        maximize_window(w)

proc unmaximize*(w: Window) =
    if w.isMaximized():
        unmaximize_window(w)

proc minimize*(w: Window) =
    if not w.isMinimized():
        minimize_window(w)

proc unminimize*(w: Window) =
    if w.isMinimized():
        unminimize_window(w)

proc show*(w: Window) =
    if not w.isVisible():
        show_window(w)

proc hide*(w: Window) =
    if w.isVisible():
        hide_window(w)

proc fullscreen*(w: Window) =
    if not w.isFullscreen():
        fullscreen_window(w)

proc unfullscreen*(w: Window) =
    if w.isFullscreen():
        unfullscreen_window(w)

proc topmost*(w: Window) =
    set_topmost_window(w)

proc untopmost*(w: Window) =
    unset_topmost_window(w)

proc setFocused*(w: Window, f: bool) =
    set_focused_window(w, f)

proc isFocused*(w: Window): bool =
    is_focused_window(w)

proc makeBorderless*(w: Window) =
    make_borderless_window(w)

proc setClosable*(w: Window, c: bool) =
    set_closable_window(w, c)

proc isClosable*(w: Window): bool =
    is_closable_window(w)

proc setMaximizable*(w: Window, m: bool) =
    set_maximizable_window(w, m)

proc isMaximizable*(w: Window): bool =
    is_maximizable_window(w)

proc setMinimizable*(w: Window, m: bool) =
    set_minimizable_window(w, m)

proc isMinimizable*(w: Window): bool =
    is_minimizable_window(w)

#---------------------

# At the top of the module, we'll need a way to store our closures
var menuCallbacks = newTable[pointer, MenuAction]()

# Helper to create a C-compatible callback
proc menuCallbackWrapper(userData: pointer) {.cdecl.} =
    if menuCallbacks.hasKey(userData):
        menuCallbacks[userData](userData)

proc newMenu*(title: string = ""): Menu =
    result = Menu(
        title: title,
        items: @[]
    )

proc addItem*(menu: Menu, label: string, action: MenuAction = nil, userData: pointer = nil): MenuItem =
    result = MenuItem(
        kind: NormalItem,
        label: label,
        enabled: true,
        checked: false,
        action: action,
        userData: userData
    )
    menu.items.add(result)

proc addSeparator*(menu: Menu): MenuItem =
    result = MenuItem(kind: SeparatorItem)
    menu.items.add(result)

proc addSubmenu*(menu: Menu, label: string, submenu: Menu): MenuItem =
    result = MenuItem(
        kind: SubmenuItem,
        submenuLabel: label,
        submenu: submenu
    )
    menu.items.add(result)

proc enable*(item: MenuItem) =
    if item.kind == NormalItem:
        item.enabled = true

proc disable*(item: MenuItem) =
    if item.kind == NormalItem:
        item.enabled = false

proc check*(item: MenuItem) =
    if item.kind == NormalItem:
        item.checked = true

proc uncheck*(item: MenuItem) =
    if item.kind == NormalItem:
        item.checked = false

proc setShortcut*(item: MenuItem, shortcut: string) =
    if item.kind == NormalItem:
        item.shortcut = shortcut

proc bindMenuItem(cMenu: ptr MenuObj, item: MenuItem): ptr MenuItemObj =
    ## One stable identity per item. The old code keyed every callback on
    ## `userData` (always nil), so Windows fired the last Share action
    ## for Facebook, Twitter and Instagram alike.
    let ident = cast[pointer](item)
    if item.action != nil:
        menuCallbacks[ident] = item.action
    result = add_menu_item(
        cMenu,
        item.label.cstring,
        if item.action != nil: menuCallbackWrapper else: nil
    )
    result.userData = ident
    if item.shortcut.len > 0:
        set_menu_item_shortcut(result, item.shortcut.cstring)
    set_menu_item_checked(result, item.checked)
    set_menu_item_enabled(result, item.action != nil and item.enabled)

proc populateCMenu(cMenu: ptr MenuObj, menu: Menu) =
    for item in menu.items:
        case item.kind
        of NormalItem:
            discard bindMenuItem(cMenu, item)
        of SeparatorItem:
            discard add_menu_separator(cMenu)
        of SubmenuItem:
            let submenuPtr = create_menu(item.submenu.title.cstring)
            populateCMenu(submenuPtr, item.submenu)
            discard add_submenu(cMenu, item.submenuLabel.cstring, submenuPtr)

proc setMenus*(w: Window, menus: openArray[Menu]) =
    if menus.len == 0:
        remove_window_menu(w)
        return

    var cMenus = newSeq[ptr MenuObj](menus.len)

    for i, menu in menus:
        cMenus[i] = create_menu(menu.title.cstring)
        populateCMenu(cMenus[i], menu)

    set_window_menu(w, cast[ptr ptr MenuObj](addr cMenus[0]), cMenus.len.csize_t)

proc removeMenuBar*(w: Window) =
    remove_window_menu(w)