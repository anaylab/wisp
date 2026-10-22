// Wisp Tabs — the caps on what the extension sends to Wisp.
//
// Pages and tab lists can be arbitrarily large, and everything the extension
// sends travels as one WebSocket frame that Wisp has to hold in memory and,
// later, trim again before any of it reaches a model. So the extension caps
// every text field and every list it sends, and says so with
// `truncated: true` rather than cutting silently (contracts.md §1).

export const MAXIMUM_TEXT_FIELD_CHARACTERS = 20000;
export const MAXIMUM_LIST_ITEMS = 500;

// Returns `{ text, truncated }`. Anything that isn't a string becomes "".
export function truncateText(text, maximumCharacters = MAXIMUM_TEXT_FIELD_CHARACTERS) {
  if (typeof text !== "string") {
    return { text: "", truncated: false };
  }
  if (text.length <= maximumCharacters) {
    return { text, truncated: false };
  }
  // Don't leave half of a surrogate pair at the end: it would turn into a
  // replacement character when Wisp decodes the frame.
  let cutIndex = maximumCharacters;
  const lastKeptCharacterCode = text.charCodeAt(cutIndex - 1);
  if (lastKeptCharacterCode >= 0xd800 && lastKeptCharacterCode <= 0xdbff) {
    cutIndex -= 1;
  }
  return { text: text.slice(0, cutIndex), truncated: true };
}

// Returns `{ items, truncated }`. Anything that isn't an array becomes [].
export function capList(items, maximumItems = MAXIMUM_LIST_ITEMS) {
  if (!Array.isArray(items)) {
    return { items: [], truncated: false };
  }
  if (items.length <= maximumItems) {
    return { items, truncated: false };
  }
  return { items: items.slice(0, maximumItems), truncated: true };
}
