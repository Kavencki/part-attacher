import { lua } from "@/bridge"

// Part Attacher - mod author: Kavencki - Giedrius P. (c) 2026
// A button in the pause menu's shared "Mods" tab. Its card (PartAttacherCard.vue) opens the mod's
// window and goes back to driving: lua/ge/extensions/partAttacher.lua, M.openFromMenu.
const BUTTON_ID = "partAttacher-open"

export async function onLoad() {
  await lua.extensions.ui_pause_actions.registerModButton({
    id: BUTTON_ID,
    tabId: "mods",
    label: "Part Attacher",
    icon: "wrench",
    componentName: "/ui/ui-vue/mods/partAttacher/PartAttacherCard.vue",
  })
}

export async function onUnload() {
  await lua.extensions.ui_pause_actions.unregisterModButton(BUTTON_ID)
}
