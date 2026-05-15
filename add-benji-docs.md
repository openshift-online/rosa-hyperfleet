---
work_id: SPEC-ADD-BENJI-DOCS
---

# Add Benji platform documentation to ROSA Regional Platform

## Problem

The ROSA Regional Platform documentation doesn't mention that it runs on the Benji infrastructure platform. This context is important for understanding the underlying infrastructure automation layer.

## Solution

Update `docs/README.md` to add a brief section explaining that the platform runs on Benji.

Add a new section called "Infrastructure Platform" (or add to an existing appropriate section) that mentions:
- The ROSA Regional Platform runs on Benji
- Benji provides the infrastructure automation platform layer
- Keep it concise (2-3 sentences)

## Files to modify

- `docs/README.md`

## Testing

No tests needed - this is documentation only. Verify the documentation renders correctly as markdown.
