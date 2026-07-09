# Feature-Gated Write-Mode Control

**Status**: Design Proposal (REVISED)  
**Jira**: [ROSAENG-61570](https://redhat.atlassian.net/browse/ROSAENG-61570)  
**Author**: Chris Doan  
**Date**: 2026-07-09 (Revised: 2026-07-09)  
**Reviewers**: Lucas (reach out for detailed requirements)  
**Related PR**: [openshift-online/rosa-hyperfleet#678](https://github.com/openshift-online/rosa-hyperfleet/pull/678/changes)

## Problem Statement

Currently, HyperFleet's field control system supports three independent dimensions:

1. **Visibility** (`+k8s:openapi-gen=false`) - whether fields appear in OpenAPI/API surface
2. **Write Mode** (`+hyperfleet:write-mode=X`) - customer mutability (mutable/immutable/service-set)
3. **Feature Gating** (`+openshift:enable:FeatureGate=X`) - per-customer entitlements based on feature set

**The limitation**: A field's write-mode is **fixed for all customers**. We cannot vary write-mode based on customer tier or feature gate enablement.

### Primary Use Case (from Slack/Jira feedback)

**Key insight**: Write-mode control needs to work **independently** of feature gating, not only for fields behind a FeatureGate.

**Scenario**: A field is **GA** (no `+openshift:enable:FeatureGate` marker) but we want to give specific customers the ability to mutate a field that is otherwise immutable or service-set.

**Example 1 - Customer-tier based control**:

- **Standard customers**: `releaseChannel` is `immutable` (set on create, cannot change)
- **Premium customers**: `releaseChannel` is `mutable` (can change anytime)

**Example 2 - Gradual rollout with feature gates**:

- **Default customers** (production): `etcd` is `service-set` (read-only, platform-managed)
- **TechPreview customers** (early adopters): `etcd` is `mutable` (customer-controlled for testing)

Today, we must choose ONE write-mode for all customers, preventing these patterns.

## Proposed Solution (REVISED)

### Follow Existing OpenShift Marker Patterns

**Decision from Slack/Jira feedback**: Instead of inventing new bracket syntax, follow the existing OpenShift marker conventions that support **multiple arguments**.

**Reference patterns** (from openshift/api):

- `+openshift:validation:FeatureGateAwareEnum:featureGate="MyAwesomeFeature",enum="Val1";"Val2"`
- `+openshift:validation:FeatureGateAwareXValidation` (CEL validation rules conditional on feature gates)

### Proposed Marker: `FeatureGateAwareWriteMode`

Add a new marker that allows different write-modes based on feature gate state:

```go
type ClusterSpec struct {
    // Simple case: no feature gate, fixed write-mode
    // +hyperfleet:write-mode=mutable
    DisplayName string `json:"displayName"`

    // GA field (no FeatureGate marker) with customer-tier-based write-mode control
    // Default: immutable for all customers
    // Override: mutable when MyPremiumFeature gate is enabled
    // +hyperfleet:write-mode=immutable
    // +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="",writeMode="immutable"
    // +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="MyPremiumFeature",writeMode="mutable"
    ReleaseChannel string `json:"releaseChannel"`

    // Gated field with different write-modes per feature set
    // Default: service-set (platform-managed)
    // TechPreview+: mutable (customer-controlled)
    // +hyperfleet:write-mode=service-set
    // +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="",writeMode="service-set"
    // +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="HyperFleetEtcdConfig",writeMode="mutable"
    // +openshift:enable:FeatureGate=HyperFleetEtcdConfig
    Etcd *EtcdSpec `json:"etcd,omitempty"`
}
```

**Syntax**:

- Base mode: `+hyperfleet:write-mode=X` (default/fallback)
- Override: `+hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="GateName",writeMode="X"`
- Empty `featureGate=""` = default (no gates enabled)
- Valid write modes: `mutable`, `immutable`, `service-set`

### Data Model Changes

**Current FieldMeta** (`pkg/markers/types.go`):

```go
type FieldMeta struct {
    FieldPath   string
    WriteMode   WriteMode    // Single mode for all
    FeatureGate string
    Hidden      bool
}
```

**Proposed FieldMeta**:

```go
type FieldMeta struct {
    FieldPath              string
    WriteMode              WriteMode                      // Base mode (fallback)
    FeatureGate            string                         // Gate required for visibility
    Hidden                 bool
    FeatureGateAwareWriteModes []FeatureGateWriteMode `json:"featureGateAwareWriteModes,omitempty"`
}

type FeatureGateWriteMode struct {
    FeatureGate string    // Empty string = default (no gates enabled)
    WriteMode   WriteMode
}
```

**JSON Registry Example 1** (GA field with customer-tier control):

```json
{
  "fieldPath": "spec.releaseChannel",
  "writeMode": "immutable",
  "featureGateAwareWriteModes": [
    { "featureGate": "", "writeMode": "immutable" },
    { "featureGate": "MyPremiumFeature", "writeMode": "mutable" }
  ]
}
```

**JSON Registry Example 2** (Gated field with different write-modes):

```json
{
  "fieldPath": "spec.etcd",
  "writeMode": "service-set",
  "featureGate": "HyperFleetEtcdConfig",
  "featureGateAwareWriteModes": [
    { "featureGate": "", "writeMode": "service-set" },
    { "featureGate": "HyperFleetEtcdConfig", "writeMode": "mutable" }
  ]
}
```

## Implementation Plan

### Phase 1: Marker Parsing

**File**: `pkg/markers/scanner.go`

Update `extractMarkers()` to recognize multi-argument FeatureGateAwareWriteMode markers:

```go
// Pattern: +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="GateName",writeMode="mutable"
var featureGateAwareWriteModePattern = regexp.MustCompile(
    `\+hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="([^"]*)",writeMode="(mutable|immutable|service-set)"`,
)

func (s *MarkerScanner) extractMarkers(field *ast.Field, fieldPath string) *FieldMeta {
    // ... existing code ...

    // Extract feature-gate-aware write-modes
    var gatedModes []FeatureGateWriteMode
    for _, match := range featureGateAwareWriteModePattern.FindAllStringSubmatch(comments, -1) {
        featureGate := match[1]  // Empty string or gate name
        mode := WriteMode(match[2])  // mutable/immutable/service-set
        gatedModes = append(gatedModes, FeatureGateWriteMode{
            FeatureGate: featureGate,
            WriteMode:   mode,
        })
    }

    if len(gatedModes) > 0 {
        meta.FeatureGateAwareWriteModes = gatedModes
    }
}
```

### Phase 2: Registry Generation

**Files**: `pkg/markers/generator.go`, `pkg/markers/json.go`

Update templates to include `GatedWriteModes`:

```go
type templateField struct {
    FieldPath       string
    WriteMode       string
    FeatureGate     string
    Hidden          bool
    GatedWriteModes map[string]string  // NEW
}
```

### Phase 3: Runtime Validation

**File**: `pkg/validation/validator.go`

Update `validateWriteMode()` to check feature-gate-aware write-mode:

```go
func (v *Validator) validateWriteMode(fieldPath string, meta registry.FieldMeta, req *Request) error {
    // Determine effective write-mode based on customer's enabled feature gates
    effectiveMode := meta.WriteMode  // Default fallback

    // Check for feature-gate-aware write-mode overrides
    if len(meta.FeatureGateAwareWriteModes) > 0 {
        // Find the most specific match based on enabled gates
        // Priority: specific gate match > default ("") > base WriteMode
        for _, override := range meta.FeatureGateAwareWriteModes {
            if override.FeatureGate == "" {
                // Default override (no gates required)
                effectiveMode = override.WriteMode
            } else if req.IsFeatureGateEnabled(override.FeatureGate) {
                // Specific gate is enabled - this takes precedence
                effectiveMode = override.WriteMode
                break  // Most specific match wins
            }
        }
    }

    // Enforce the effective mode
    switch effectiveMode {
    case registry.ServiceSet:
        return &ValidationError{
            FieldPath: fieldPath,
            Reason:    "field is platform-managed (service-set) for your account tier",
        }
    // ... rest of validation
    }
}
```

**Note**: The validation Request needs a new method:

```go
type Request struct {
    // ... existing fields ...
    EnabledFeatureGates []string  // NEW: List of enabled gates for this customer
}

func (r *Request) IsFeatureGateEnabled(gateName string) bool {
    for _, gate := range r.EnabledFeatureGates {
        if gate == gateName {
            return true
        }
    }
    return false
}
```

### Phase 4: Testing

**File**: `pkg/validation/validator_test.go`

Add test cases:

```go
func TestValidator_GatedWriteMode(t *testing.T) {
    tests := []struct {
        name        string
        fieldPath   string
        featureSet  featuregate.FeatureSet
        operation   Operation
        expectError bool
    }{
        {
            name:        "service-set for Default, mutable for TechPreview",
            fieldPath:   "spec.etcd",
            featureSet:  featuregate.Default,
            operation:   OperationCreate,
            expectError: true,  // service-set blocks customer writes
        },
        {
            name:        "mutable for TechPreview",
            fieldPath:   "spec.etcd",
            featureSet:  featuregate.TechPreviewNoUpgrade,
            operation:   OperationCreate,
            expectError: false,  // mutable allows writes
        },
    }
    // ...
}
```

## Migration Strategy

### Backward Compatibility

Existing fields without gated write-modes continue to work unchanged:

- No breaking changes to current markers
- New syntax is opt-in
- Empty `GatedWriteModes` map treated as "no overrides"

### Rollout

1. Merge code changes
2. Update documentation
3. Add gated write-modes to specific fields as needed (opt-in)
4. Monitor validation metrics

No mass migration required - fields adopt gated modes incrementally.

## Examples

### Example 1: GA Field with Customer-Tier Write-Mode Control

```go
// GA field (no FeatureGate marker) with different write-modes by customer tier
// Standard customers: immutable (set on create only)
// Premium customers (with MyPremiumFeature gate): mutable
// +hyperfleet:write-mode=immutable
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="",writeMode="immutable"
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="MyPremiumFeature",writeMode="mutable"
ReleaseChannel string `json:"releaseChannel"`
```

### Example 2: Gated Field with Progressive Write-Mode Rollout

```go
// Field behind feature gate with different write-modes
// Default: service-set (platform-managed, read-only)
// TechPreview+: mutable (customer-controlled for testing)
// +hyperfleet:write-mode=service-set
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="",writeMode="service-set"
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="HyperFleetEtcdConfig",writeMode="mutable"
// +openshift:enable:FeatureGate=HyperFleetEtcdConfig
Etcd *EtcdSpec `json:"etcd,omitempty"`
```

### Example 3: Simple Case (No Gate-Aware Control)

```go
// Works today, continues to work unchanged
// Fixed write-mode for all customers
// +hyperfleet:write-mode=mutable
Tags map[string]string `json:"tags,omitempty"`
```

### Example 4: Multiple Gate-Based Overrides

```go
// Different write-modes for different gates
// No gates: immutable (standard tier)
// BetaFeature1: mutable (beta testers)
// PremiumFeature: mutable (premium tier)
// +hyperfleet:write-mode=immutable
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="",writeMode="immutable"
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="BetaFeature1",writeMode="mutable"
// +hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="PremiumFeature",writeMode="mutable"
AdvancedConfig *Config `json:"advancedConfig,omitempty"`
```

## Trade-offs and Alternatives

### Alternative 1: Bracket Syntax (Original Proposal)

**Original proposal**: `+hyperfleet:write-mode[FeatureSetName]=mutable`

**Rejected (from Slack feedback)**: Invents new syntax instead of following existing OpenShift patterns. OpenShift API already has established multi-argument marker patterns like `FeatureGateAwareEnum` and `FeatureGateAwareXValidation`.

### Alternative 2: Separate Fields Per Customer Tier

Create different field names: `releaseChannelStandard`, `releaseChannelPremium`.

**Rejected**: API surface explosion, confusing for customers, doesn't scale.

### Alternative 3: Runtime-Only Configuration

Use environment variables or database config to control write-mode at runtime.

**Rejected**: Not declarative, harder to audit, doesn't integrate with existing marker system, can't generate accurate OpenAPI docs.

### Alternative 4: Extend FeatureSet Enum

Add more feature sets: `PremiumDefault`, `PremiumTechPreview`, etc.

**Rejected**: Feature sets are for API stability tiers (GA/TechPreview/DevPreview), not customer subscription tiers. Mixing concerns.

### Chosen Approach: FeatureGateAwareWriteMode

**Pros**:

- Follows existing OpenShift API patterns (`FeatureGateAwareEnum`, `FeatureGateAwareXValidation`)
- Declarative (visible in code)
- Works independently of feature gating (GA fields can use it)
- Backward compatible (optional marker)
- Scales to many fields and multiple gates

**Cons**:

- More verbose than bracket syntax
- Requires parser changes
- Validation logic more complex (must check enabled gates)
- Need to track customer's enabled feature gates at runtime

## Open Questions

1. **Marker name**: Is `FeatureGateAwareWriteMode` the right name? Should it match the pattern `+hyperfleet:validation:X` or be a different namespace?
   - **Current**: `+hyperfleet:validation:FeatureGateAwareWriteMode`
   - **Alternative**: `+hyperfleet:FeatureGateAwareWriteMode` (shorter)

2. **Multiple gate behavior**: If a customer has multiple gates enabled, which write-mode wins?
   - **Recommendation**: First specific match in marker order (earliest in source code)
   - **Alternative**: Most permissive (mutable > immutable > service-set)

3. **Validation error messages**: How detailed should errors be for gate-aware rejections?
   - **Recommendation**: "field is {write-mode} for your account tier" (don't expose gate names to customers)

4. **CRD variant generation**: Should CRD YAML show different write-modes per variant?
   - **Recommendation**: Not initially - CRDs show schema, not validation rules. This is runtime validation.

5. **Migration path**: Should we auto-migrate existing fields or require explicit opt-in?
   - **Recommendation**: Explicit opt-in only. No automatic migration.

6. **Customer gate enablement**: How do we determine which gates are enabled for a customer at runtime?
   - **Option A**: Lookup from database based on subscription tier
   - **Option B**: Include in request authentication/authorization context
   - **Option C**: Explicit parameter in Platform API request

## Feedback Received

### From Slack/Jira Discussion (2026-07-09)

**Key insights** (Jira comment by ship-help-jira):

1. **Primary use case clarification**: Write-mode control needs to work **independently** of feature gating. It's not only for fields behind a FeatureGate. The main scenario is: a field is GA (no `+openshift:enable:FeatureGate` marker) and we still want to give particular customers the ability to mutate a field that is otherwise immutable.

2. **Marker syntax direction**: Follow existing OpenShift marker conventions that support **multiple arguments**, rather than inventing new bracket syntax like `[FeatureSetName]`.

3. **Reference patterns to study**:
   - `+openshift:validation:FeatureGateAwareEnum` - allows different enum values depending on which feature gates are enabled
   - `+openshift:validation:FeatureGateAwareXValidation` - "probably the most useful"; allows conditional CEL validation rules based on feature gate state

4. **Pattern structure**: The existing pattern allows:
   - A default version with `featureGate=""` (defaults) with one set of values
   - Additional versions with specific feature gates and different values

**Example from openshift/api**:

```go
+openshift:validation:FeatureGateAwareEnum:featureGate="MyAwesomeFeature",enum="Val1";"Val2"
```

### Design Revisions Based on Feedback

✅ **Changed marker syntax** from `+hyperfleet:write-mode[FeatureSetName]=X` to `+hyperfleet:validation:FeatureGateAwareWriteMode:featureGate="GateName",writeMode="X"`

✅ **Clarified use case** to emphasize GA fields with customer-tier control, not just gated fields

✅ **Added data model** for list of `FeatureGateWriteMode` instead of map, to preserve order and allow empty-string default

✅ **Updated validation logic** to check customer's enabled gates, not just feature sets

## Next Steps

1. **Review revised design** with Lucas and team
2. **Gather feedback** on:
   - Marker namespace (`+hyperfleet:validation:` vs `+hyperfleet:`)
   - Multiple-gate priority behavior
   - Customer gate enablement mechanism
3. **Study openshift/api patterns** in detail (FeatureGateAwareEnum, FeatureGateAwareXValidation)
4. **Prototype** marker parsing to validate regex approach
5. **Implement** phases 1-4 after approval
6. **Update** `docs/feature-gates.md` with examples

## References

- **Jira**: [ROSAENG-61570](https://redhat.atlassian.net/browse/ROSAENG-61570)
- **Parent Epic**: [ROSAENG-61383](https://redhat.atlassian.net/browse/ROSAENG-61383)
- **Current Implementation**: `pkg/featuregate/`, `pkg/validation/`, `pkg/markers/`
- **OpenShift API Pattern**: https://github.com/openshift/api/tree/master/tools/codegen
