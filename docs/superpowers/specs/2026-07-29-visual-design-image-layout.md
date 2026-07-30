# Visual Design Image Layout

## Goal

Make the visuals in `docs/VISUAL_DESIGN.md` easier to compare and consistently
sized while retaining GitHub-compatible Markdown and HTML.

## Layout

- Place each related pair or trio in a centered Markdown table.
- Center every standalone image with `<p align="center">`.
- Use 250-pixel widths for full phone screenshots in tables and 300-pixel
  widths when a phone screenshot stands alone.
- Use 300–400-pixel widths for cropped detail screenshots based on their aspect
  ratio.
- Use 400–450-pixel widths for wide desktop screenshots.
- Keep image alt text descriptive.

## Indicator Table

Place the three Conductor activity indicators in one table with the column
headings `Horizontal`, `Random`, and `Spinner`. Render all three at a width of
110 pixels so their differing source dimensions do not affect their displayed
size.

## Related Spinner Comparisons

Place each header/chat spinner pair in a two-column table. Use a wider display
for the header crop and a 250-pixel display for the full phone recording.

## Validation

- Every image path must resolve to an existing asset.
- All 29 assets must remain referenced exactly once.
- No standalone image may remain uncentered.
- Every adjacent related pair or trio must be represented by a table.
