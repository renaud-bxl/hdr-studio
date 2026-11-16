"use strict";

const range = document.getElementById("split");
const comparison = document.getElementById("comparison");
function showSplit() {
  const value = Number(range.value);
  comparison.style.setProperty("--split", value + "%");
  range.setAttribute("aria-valuetext", value + " % d’illustration SDR, " + (100 - value) + " % HDR");
}
range.addEventListener("input", showSplit);
showSplit();

const copy = document.getElementById("copy");
const copyLabel = copy.querySelector("span");
const command = document.getElementById("install-command");
const status = document.getElementById("copy-status");
let resetTimer;
copy.hidden = false;

copy.addEventListener("click", async () => {
  clearTimeout(resetTimer);
  try {
    await navigator.clipboard.writeText(command.textContent.trim());
    copyLabel.textContent = "Copié !";
    status.textContent = "Commande copiée. Colle-la dans Terminal.";
    resetTimer = setTimeout(() => {
      copyLabel.textContent = "Copier";
      status.textContent = "Installation sans sudo.";
    }, 4500);
  } catch {
    const selection = window.getSelection();
    const textRange = document.createRange();
    textRange.selectNodeContents(command);
    selection.removeAllRanges();
    selection.addRange(textRange);
    status.textContent = "Commande sélectionnée. Utilise ⌘C pour la copier.";
  }
});
