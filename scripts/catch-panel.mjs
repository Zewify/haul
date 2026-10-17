// Presses Start in Downhaul's catch panel through accessibility (scripts/press-start.swift). Never a keystroke: a
// keystroke goes to whichever app is in front, which may be the user's own browser, not Downhaul.
import { execFile } from 'node:child_process';

const script = new URL('./press-start.swift', import.meta.url).pathname;
const press = () => new Promise((resolve) => execFile('swift', [script], (error) => resolve(error ? error.code : 0)));

/// Waits up to `seconds` for the panel and presses Start. Returns true once pressed, false if it never could be.
export async function pressStart(seconds = 30) {
  const until = Date.now() + seconds * 1000;
  while (Date.now() < until) {
    const code = await press();
    if (code === 0) return true;
    if (code === 2) return false;   // Start is disabled: the panel is showing why
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}
