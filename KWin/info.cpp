/* Copyright (c) 2024-2025, Litwak913
   At GPL-3.0 License
*/

#include "arkpetsintegration.h"

#include "kwin/cursor.h"
#include "kwin/virtualdesktops.h"
#include "kwin/window.h"
#include "kwin/workspace.h"

using namespace KWin;
namespace ArkPets
{

Details ArkPetsIntegration::Details(const QString &uuid)
{
    const auto window = Workspace::self()->findWindow(QUuid::fromString(uuid));
    if (!window || !window->isClient()) {
        qWarning() << "[ArkPets] Window Not Found";
        return {0, 0, 0, 0, QLatin1String(""), QLatin1String(""), false, QLatin1String("")};
    }
    bool minimized = window->isMinimized();
    bool in_current_workspace = false;
    if (window->isOnAllDesktops() || window->isOnCurrentDesktop()) {
        in_current_workspace = true;
    }
    struct Details detail = {.x = qRound(window->x()),
                             .y = qRound(window->y()),
                             .w = static_cast<uint>(qRound(window->width())),
                             .h = static_cast<uint>(qRound(window->height())),
                             .title = window->caption(),
                             .wclass = window->resourceClass(),
                             .visible = (in_current_workspace && !minimized),
                             .id = window->internalId().toString(QUuid::WithoutBraces)};
    return detail;
}

DetailsList ArkPetsIntegration::List()
{
    DetailsList winids;
    const auto current_desktop = VirtualDesktopManager::self()->currentDesktop()->id();
    for (const Window *window : Workspace::self()->stackingOrder()) {
        // Never query a window KWin is in the middle of tearing down.
        //
        // LayerShellV1Window::destroyWindow() calls markAsDeleted() and then unref(), which
        // only destructs the object once KWin's reference count reaches zero - so a window can
        // stay in Workspace::stackingOrder() while already marked deleted. In that state its
        // m_shellSurface points at a LayerSurfaceV1Interface that has since been destroyed.
        //
        // KWin's own accessors are inconsistent about guarding this. In the same class,
        // wantsInput() reads `!isDeleted() && m_shellSurface->acceptsFocus()`, while hasStrut()
        // is a bare `m_shellSurface->exclusiveZone() > 0`. Calling hasStrut() on such a window
        // takes the whole compositor down; this was captured on KWin 6.7.4 and confirmed from
        // the core dump:
        //
        //   frame #6  ArkPetsIntegration::List()          (in this plugin)
        //   frame #5  LayerShellV1Window::hasStrut()      `mov 0x570(%rdi),%rdi; call ...`
        //   frame #4  LayerSurfaceV1Interface::exclusiveZone()  `movsd 0xf8(%rax),%xmm0`
        //
        // with rdi == m_shellSurface == 0x55d88c685a30. That address is a freed malloc chunk:
        // the size field at -8 reads 0x21 (32 bytes, PREV_INUSE) - which is exactly the size of
        // a LayerSurfaceV1Interface, vtable plus QObject plus its `d` pointer - and the chunk's
        // first 16 bytes hold glibc tcache next/key pointers, the signature of a freed block
        // waiting to be reused. exclusiveZone() then read its private pointer from the stale
        // bytes at +0x10, got 0x20, and faulted on *(0x20 + 0xf8) == address 0x118.
        //
        // Since ArkPets calls List() once per rendered frame, that is not a rare race for us.
        //
        // This guard also makes the strut query below safe: Window::strutRects() dispatches to the
        // virtual strutRect(StrutArea), which LayerShellV1Window overrides to read its layer
        // surface - the same unguarded accessor as hasStrut(). A live layer surface is fine and
        // must keep contributing its exclusive zone, so only the deleted case is skipped.
        if (window->isDeleted())
            continue;

        bool minimized = window->isMinimized();
        bool in_current_workspace = false;
        if (window->isOnAllDesktops() || window->isOnCurrentDesktop()) {
            in_current_workspace = true;
        }
        struct Details detail = {.x = 0,
                                 .y = 0,
                                 .w = 0,
                                 .h = 0,
                                 .title = window->caption(),
                                 .wclass = window->resourceClass(),
                                 .visible = (in_current_workspace && !minimized),
                                 .id = window->internalId().toString(QUuid::WithoutBraces)};
        if (window->isNormalWindow()) {
            // Plain member reads, safe for every window type. This is also the path that
            // KWin's scope-to-type mapping sends most layer-shell surfaces down - scope
            // "panel", which is what caelestia's shell and waybar use, is not in KWin's
            // known-scope table and so becomes WindowType::Normal.
            detail.x = window->x();
            detail.y = window->y();
            detail.w = static_cast<uint>(window->width());
            detail.h = static_cast<uint>(window->height());
            winids << detail;
            continue;
        }
        for (const StrutRect &sr : window->strutRects()) {
            detail.x = sr.x();
            detail.y = sr.y();
            detail.w = static_cast<uint>(sr.width());
            detail.h = static_cast<uint>(sr.height());
            winids << detail;
        }
    }
    return winids;
}

MousePos ArkPetsIntegration::Mouse()
{
    const auto point = Cursors::self()->mouse()->pos().toPoint();
    return {.x = point.x(), .y = point.y()};
}

} // namespace ArkPets
