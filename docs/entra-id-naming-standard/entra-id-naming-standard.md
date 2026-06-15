# Entra ID Naming — Cheat Sheet

A name carries the **intent** of the access: *what it is, and who it's for.* It does not carry the **content** (what's in it right now) or the **assignment** (who got it, when, how long). Those change. The name shouldn't.

> Three layers: **name** = intent (which) · **description** = content (what + why) · **governance** = who, when, how long.

---

## The one idea

**An access package is a stable identity. The resources inside it are swappable content. Name the identity, never the content.**

- The **package** is what you keep: it holds every approved assignment and all the history.
- The **resource** is disposable: a license group today, an app role or a site tomorrow.
- Change the content by swapping the resource. The package, its name, and its approvals stay put.

**Example — upgrading a baseline, no re-approvals:**
`License - Baseline 5` grants `LIC-M365-E5`. The company moves that baseline to E7. You:
1. Create `LIC-M365-E7`, assign the E7 license to it.
2. In the package, remove the old resource, add the new one.

Same package, same name, same approvals. Everyone on Baseline 5 is added to the new group automatically and picks up E7. Nothing to migrate.

---

## The persona test — does it go in the name?

Hand the *exact same access* to a different persona. Still the same access?

- **Same access** → persona is only *eligibility* → policy → **leave it out.**
  *(A baseline license: an E5 is an E5 for everyone who holds it.)*
- **Different entitlement** → persona is *part of the access* → **put it in.**
  *(`App - Employee - SAP User Access`.)*

---

## Object → structure → example

| Object | Structure | Example |
|---|---|---|
| **Access package** | what it is → *(persona, if part of the access)* → what specifically | `License - Baseline 5` · `App - Employee - SAP User Access` · `Role - ICT - User Administration` |
| **Resource** (swappable content) | function prefix → what it carries — *no persona* | `LIC-M365-E5` · `LIC-M365-F3` · `PIM-EntraGovernanceAdmin` |
| **Catalog** | persona container | `Identity - Employee` · `Identity - Subcontractor` |
| **Lifecycle workflow** | persona → event → time as an [ISO 8601 duration](https://en.wikipedia.org/wiki/ISO_8601#Durations) | `Subcontractor - Pre-Onboard (P7D before)` · `Subcontractor - Activate (P0D)` · `Subcontractor - License Cleanup (P14D after)` |

*Offsets use ISO 8601 durations: `P7D` = seven days, `P0D` = the event day itself. A duration has no direction of its own, so add `before` or `after` the trigger date. (Microsoft stores this as a signed `offsetInDays`, e.g. -7; the name spells it out instead.) See [ISO 8601](https://en.wikipedia.org/wiki/ISO_8601#Durations).*

The same resource can sit behind more than one package (an employee baseline and a subcontractor upgrade; a department and a project). Same access, different route in. Name the resource for what it grants, never for who routed to it. Entra reference-counts the routes for you.

---

## Keep out of the name

- **Assignment** — who requests, who approves, how long. That's policy, and it changes.
- **Object type / class** — `SG`, `AAD`, `M365`, `DL`. The directory already knows. (Function prefixes like `LIC`, `PIM` are fine — that's what it *does*, not what it *is*.)
- **Persona when it's only eligibility** — baselines stay persona-free; persona lives in the policies.
- **Product, on the package** — keep `E5` / `F3` on the resource so you can swap it. Put it on the package only when the product genuinely *is* the intent and won't be swapped out from under the name.

## The number is a label, not a level

`Baseline 1`, `Baseline 2` don't rank anything. The description says what each one contains. The name says *which*; the description says *what*.

---

## Separators

Pick one style per object type and never switch. **Which** separator doesn't matter — `LIC-M365-E5`, `LIC_M365_F3`, and `LIC M365 P2` are three different strings to a search box, and that's the only thing that bites you.

---

## Gut check before you save a name

> Could someone tell what this is from the name alone — without opening it, and without already knowing what you know? And: will it still be true after the next change?

**Yes** → it's doing its job. **No** → you've labeled it, not named it.