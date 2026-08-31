---
name: Obsidian Cyber
colors:
  surface: '#141313'
  surface-dim: '#141313'
  surface-bright: '#3a3939'
  surface-container-lowest: '#0e0e0e'
  surface-container-low: '#1c1b1b'
  surface-container: '#201f1f'
  surface-container-high: '#2a2a2a'
  surface-container-highest: '#353434'
  on-surface: '#e5e2e1'
  on-surface-variant: '#c4c7c8'
  inverse-surface: '#e5e2e1'
  inverse-on-surface: '#313030'
  outline: '#8e9192'
  outline-variant: '#444748'
  surface-tint: '#c6c6c7'
  primary: '#ffffff'
  on-primary: '#2f3131'
  primary-container: '#e2e2e2'
  on-primary-container: '#636565'
  inverse-primary: '#5d5f5f'
  secondary: '#c4c6cd'
  on-secondary: '#2e3036'
  secondary-container: '#46494f'
  on-secondary-container: '#b6b8bf'
  tertiary: '#ffffff'
  on-tertiary: '#003737'
  tertiary-container: '#00fbfb'
  on-tertiary-container: '#007070'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e2e2e2'
  primary-fixed-dim: '#c6c6c7'
  on-primary-fixed: '#1a1c1c'
  on-primary-fixed-variant: '#454747'
  secondary-fixed: '#e1e2e9'
  secondary-fixed-dim: '#c4c6cd'
  on-secondary-fixed: '#191c21'
  on-secondary-fixed-variant: '#44474c'
  tertiary-fixed: '#00fbfb'
  tertiary-fixed-dim: '#00dddd'
  on-tertiary-fixed: '#002020'
  on-tertiary-fixed-variant: '#004f4f'
  background: '#141313'
  on-background: '#e5e2e1'
  surface-variant: '#353434'
  background-obsidian: '#0B0C0E'
  surface-layer: '#1B1E23'
  surface-border: '#31363F'
  status-recording: '#FF4D4F'
  button-outline: '#BEC4CC'
typography:
  prompter-display:
    fontFamily: Inter
    fontSize: 42px
    fontWeight: '700'
    lineHeight: 52px
    letterSpacing: -0.02em
  prompter-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 32px
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-caps:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '700'
    lineHeight: 16px
    letterSpacing: 0.08em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  stack-sm: 8px
  stack-md: 16px
  stack-lg: 32px
  gutter: 16px
  margin-edge: 24px
  touch-target-min: 48px
---

## Brand & Style

Obsidian Cyber is a high-performance, developer-centric aesthetic designed for teleprompter and script management applications. It targets professional creators who require a focused, low-fatigue environment that feels both cutting-edge and dependable.

The style is a sophisticated blend of **Glassmorphism** and **Cyber-Minimalism**. It utilizes deep obsidian backgrounds, translucent "glass" surfaces for content cards, and sharp neon accents (Cyan and Recording Red) to guide the eye. The interface feels like a high-end heads-up display (HUD), emphasizing clarity, rhythmic spacing, and technical precision.

## Colors

The palette is anchored by **Background Obsidian (#0B0C0E)**, providing an ultra-dark canvas that minimizes glare and maximizes text legibility. 

- **Primary White:** Reserved for high-priority text and core interaction states.
- **Cyan Accent:** Used sparingly for interactive borders and hover states to provide a "neon" glow effect.
- **Recording Red:** A functional accent used specifically for active status indicators and "Record" actions, featuring a subtle pulse animation.
- **Glass Surfaces:** Semi-transparent layers built from `surface-layer` with backdrop blurs to create depth without losing the dark aesthetic.

## Typography

The system uses **Inter** exclusively to maintain a utilitarian, Swiss-inspired clarity. 

- **Display Hierarchy:** Large, tight-tracked headlines (`prompter-display`) are used for branding and main prompts.
- **Rhythm:** Line heights are generous (1.5x for body) to ensure scripts are easy to read at a distance.
- **Information Density:** Captions and metadata use `label-caps` (all-caps with tracking) to distinguish secondary info from narrative text.

## Layout & Spacing

The system follows a **Fixed-Width Content Model** centered on a maximum 768px (3xl) canvas for optimal reading speed. 

- **Margins:** A consistent 24px edge margin protects content on mobile.
- **Vertical Rhythm:** Defined by `stack` increments. 32px (`stack-lg`) separates major sections, while 16px (`stack-md`) handles grouping within sections.
- **Mobile Navigation:** Uses a floating, pill-shaped bottom bar to keep core actions within the "thumb zone."

## Elevation & Depth

Depth is achieved through **Tonal Stacking** and **Glassmorphism** rather than traditional drop shadows.

- **Level 0:** Background Obsidian (The base).
- **Level 1 (Glass Cards):** 80% to 40% opacity gradients of `surface-layer` with a 12px backdrop blur and a 1px `surface-border`.
- **Level 2 (Interactive Hero):** Solid `surface-layer` with a low-opacity Cyan border and a subtle cyan outer glow (`0 0 20px rgba(0,255,255,0.1)`) on hover.
- **Navigation:** Top and bottom bars use high-opacity glass (90%) to maintain context while ensuring legibility of underlying content.

## Shapes

The shape language is primarily **Rounded**, conveying a modern and premium feel.

- **Standard Containers:** Cards and sections use a 0.5rem (8px) or 0.75rem (12px) radius.
- **Primary Actions:** Hero buttons use `rounded-xl` (12px) to stand out.
- **Navigation & Controls:** Floating nav bars and secondary "Add" buttons use `full` (pill) rounding to distinguish them from content containers.

## Components

- **Hero Button:** Large-scale action with a Cyan border tint, containing a central icon and `prompter-lg` text. Features a `pulse-recording` animation for the status dot.
- **Glass Cards:** Used for list items. They should have a subtle hover transition that shifts the background to a slightly brighter `surface-bright/50` and changes title text to the primary accent color.
- **Pill Buttons:** Secondary actions (like "New Script") use a thin `button-outline` with a pill shape and leading icon.
- **Floating Bottom Nav:** A high-contrast pill containing a prominent circular primary action (Home) and ghost-style secondary icons.
- **Metadata Tags:** Small, capitalized labels separated by dot-dividers for script details (time, word count, date).