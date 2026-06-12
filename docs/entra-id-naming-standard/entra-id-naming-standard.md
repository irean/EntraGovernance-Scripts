# Entra ID Naming — Cheat Sheet

A name carries the **shape** of the access — *what it is, what it grants, and who it's built for when that's part of the access.* It never carries how access is **assigned**. That's policy.

> Three layers: **name** = shape · **description** = the why · **governance** = who, when, how long.

---

## The persona test — does it go in the name?

Hand the *exact same access* to a different persona. Is it still the same access?

- **Same access** → the persona is only about *eligibility* → it's policy → **leave it out.**
  *(Licenses: a Tier is the same Tier for everyone who holds it.)*
- **Different entitlement** → the persona is *part of the access* → **put it in.**
  *(An app or role bundle built specifically for one persona.)*

---

## Object → structure → example

| Object | Structure | Example |
|---|---|---|
| **Access package** | what it is → *(persona, if part of the access)* → what specifically | `License - Tier 5` · `App - Employee - SAP User Access` · `Role - ICT - User Administration` |
| **Catalog** | persona container | `Identity - Employee` · `Identity - Subcontractor` |
| **Lifecycle workflow** | persona → event → time (offset) | `Subcontractor - License Prep (D7Before)` · `Subcontractor - Activate (D0)` · `Subcontractor - License Cleanup (D14After)` |
| **Group (resource)** | function prefix → what — *no persona* | `LIC-Tier5` · `LIC-Tier1` · `PIM-EntraGovernanceAdmin-ICT` |

The same group can be reached by more than one persona, or from more than one access package (a department's and a project's). The access is the same — only the route in differs, and the route is tracked in the workflows, packages, and policies. So the group is named for the access, never the route.

---

## Always leave out

- **Assignment** — who requests, who approves, how long → policy, and it changes.
- **Object type / directory class** — `SG`, `AAD`, `M365`, `DL` → the platform already knows.
- **Product when a level works** — `E5` → `Tier 5`. The level is stable; the SKU isn't.
- **Persona when it's only eligibility** — licenses live as `LIC-Tier5`, no `Employee`.

## Keep / fair game

- **Function prefixes** — `LIC`, `PIM`: what the object *does*, not what it *is*.
- **Persona when it's part of the access** — `App - Employee - ...`.
- **One persona echoed in catalog + package** — deliberate, so the package name reads on its own in a log.

---

## Separators (this standard)

- **Access packages & catalogs** (written out): `Word - Word - Word` — spaces around the hyphen.
- **Groups** (short tokens): `PREFIX-Token` — hyphen, no spaces.
- **No underscores.** Offsets stay compact: `(D7Before)`, `(D0)`, `(D14After)`.
- One separator style per object type, every time — that's what makes names parseable by eye and by script.

Which separator you pick doesn't matter — pick one and stick to it. The only mistake is switching halfway: LIC-Tier5, LIC_Tier1, and LIC Tier 3 are three different strings to a search box.

---

## Gut check before you save a name

> Could someone tell what this access is from the name alone — without opening it, and without already knowing what you know?

**Yes** → it's doing its job. **No** → you've labeled it, not named it.
