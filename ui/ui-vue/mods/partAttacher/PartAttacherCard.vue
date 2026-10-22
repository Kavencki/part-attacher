<template>
  <div class="pa-card">
    <div class="pa-header">
      <div class="pa-title">Part Attacher</div>
      <div class="pa-version">{{ version }}</div>
    </div>
    <div class="pa-body">
      <div class="pa-author">Mod author: Kavencki - Giedrius P.</div>
      <div class="pa-text">{{ t.desc }}</div>
      <BngButton class="pa-open" :accent="ACCENTS.main" @click="open">{{ t.open }}</BngButton>
      <div class="pa-hint">{{ t.hint }}</div>
    </div>
  </div>
</template>

<script setup>
// Part Attacher - mod author: Kavencki - Giedrius P. (c) 2026
// The card of the Mods tab button (index.js): opens the mod's window and closes the pause menu.
import { ref, computed, onMounted } from "vue"
import { BngButton, ACCENTS } from "@/common/components/base"

const TEXT = {
  en: {
    desc: "Any part from any vehicle on your vehicle, engine / gearbox / suspension / turbo swaps, universal drivetrain, safety electronics.",
    open: "OPEN PART ATTACHER",
    hint: "Opens the window and goes back to driving. Key: Ctrl + Shift + Y.",
  },
  lt: {
    desc: "Bet kuri detale is bet kurios masinos ant tavo masinos, variklio / dezes / pakabos / turbo swap'ai, universalios pavaros, saugos elektronika.",
    open: "ATIDARYTI PART ATTACHER",
    hint: "Atidaro langa ir grizta i vaziavima. Klavisai: Ctrl + Shift + Y.",
  },
}

const lang = ref("en")
const version = ref("")
const t = computed(() => TEXT[lang.value] || TEXT.en)

function engineLua(script, cb) {
  if (window.bngApi && window.bngApi.engineLua) window.bngApi.engineLua(script, cb)
}

function open() {
  engineLua("if not partAttacher then extensions.load('partAttacher') end partAttacher.openFromMenu()")
}

onMounted(() => {
  // the window's own language (its Language / Kalba buttons) and version
  engineLua("partAttacher and partAttacher.getLang and partAttacher.getLang() or 'en'", res => {
    if (typeof res === "string" && TEXT[res]) lang.value = res
  })
  engineLua("partAttacher and partAttacher.getVersion and partAttacher.getVersion() or ''", res => {
    if (typeof res === "string") version.value = res
  })
})
</script>

<style scoped lang="scss">
* {
  box-sizing: border-box;
}

.pa-card {
  display: flex;
  flex-direction: column;
  width: 100%;
  overflow: hidden;
  font-family: 'Overpass', sans-serif;
  color: #fff;
  background-color: var(--bng-off-black, rgba(15, 15, 15, 0.95));
  border-radius: 6px;
}

.pa-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  padding: 0.5em 1em 0.8em;
  background-color: rgba(0, 0, 0, 0.2);
  border-bottom: 2px solid var(--bng-orange-550, #f60);

  .pa-title {
    font-size: 1.3rem;
    font-weight: 600;
  }

  .pa-version {
    font-size: 0.9rem;
    color: rgba(255, 255, 255, 0.6);
  }
}

.pa-body {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
  padding: 1em;

  .pa-author {
    font-weight: 600;
    color: #ffc738;
  }

  .pa-text {
    line-height: 1.4;
    color: rgba(255, 255, 255, 0.85);
  }

  .pa-open {
    align-self: flex-start;
    padding: 0.4em 1.4em;
    font-size: 1.1rem;
  }

  .pa-hint {
    font-size: 0.9rem;
    color: rgba(255, 255, 255, 0.6);
  }
}
</style>
