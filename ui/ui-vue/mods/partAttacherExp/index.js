import { lua } from "@/bridge"

// Part Attacher Experimental - mod author: Kavencki - Giedrius P. (c) 2026
// A button in the pause menu's shared "Mods" tab. Its card (PartAttacherExpCard.vue) opens the mod's
// window and goes back to driving: lua/ge/extensions/partAttacherExp.lua, M.openFromMenu.
const BUTTON_ID = "partAttacherExp-open"

export async function onLoad() {
  await lua.extensions.ui_pause_actions.registerModButton({
    id: BUTTON_ID,
    tabId: "mods",
    label: "Part Attacher Experimental",
    icon: "wrench",
    componentName: "/ui/ui-vue/mods/partAttacherExp/PartAttacherExpCard.vue",
  })
}

export async function onUnload() {
  await lua.extensions.ui_pause_actions.unregisterModButton(BUTTON_ID)
}
