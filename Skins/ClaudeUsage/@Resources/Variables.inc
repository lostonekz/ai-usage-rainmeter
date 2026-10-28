[Variables]
; ============================================
; Claude Usage Widget - Configuration
; ============================================

; Refresh interval in seconds (default: 300 = 5 minutes)
RefreshInterval=300

; Path to PowerShell script (relative to @Resources folder)
ScriptPath=#@#Scripts\Get-ClaudeUsage.ps1

; ============================================
; Scale
; ============================================
; Master zoom for the whole widget.
; 1 = the original size, 2 = double, 1.5 = halfway. Decimals are fine.
; Every dimension, offset and font size is multiplied by this.
; Change it and right-click the skin -> Refresh.
Scale=2

; ============================================
; Colors (RGBA format: RRR,GGG,BBB,AAA)
; ============================================

; Background
BackgroundColor=30,30,35,240

; Text colors
TextColor=220,220,225,255
TextColorDim=140,140,150,255
TextColorBright=255,255,255,255

; Status colors
NormalColor=130,180,130,255
WarningColor=220,160,60,255
CriticalColor=220,80,80,255
HighlightColor=100,200,255,255

; Bar colors
BarBackgroundColor=50,50,55,255
BarNormalColor=100,180,255,255
BarScopedColor=180,130,255,255
BarCodexColor=80,200,170,255
BarWarningColor=255,180,60,255
BarCriticalColor=255,80,80,255

; Accent/border color
AccentColor=100,100,110,255

; Section heading color
SectionColor=150,150,165,255

; ============================================
; Dimensions - base values, multiplied by #Scale#
; ============================================

; Widget size
WidgetWidth=(280*#Scale#)
WidgetHeight=(397*#Scale#)
WidgetPadding=(15*#Scale#)
CornerRadius=(8*#Scale#)

; Bar dimensions
BarHeight=(8*#Scale#)
BarWidth=(250*#Scale#)

; Vertical rhythm
HeaderY=(12*#Scale#)
SectionY=(42*#Scale#)
RowGap=(8*#Scale#)
BarGap=(3*#Scale#)
TextGap=(2*#Scale#)
FooterGap=(6*#Scale#)
SectionGap=(10*#Scale#)
AfterSectionGap=(4*#Scale#)
GearOffset=(70*#Scale#)

; Horizontal gaps between inline text runs
GapTiny=(1*#Scale#)
GapSmall=(3*#Scale#)
GapMed=(4*#Scale#)
GapWide=(5*#Scale#)
GapLabel=(6*#Scale#)

; Font settings
FontFace=Segoe UI
FontSizeIcon=(14*#Scale#)
FontSizeTitle=(12*#Scale#)
FontSizeLabel=(10*#Scale#)
FontSizeSmall=(9*#Scale#)
FontSizeSection=(8*#Scale#)
ErrorBannerHeight=(14*#Scale#)
SectionHeight=(12*#Scale#)

; ============================================
; Thresholds (percentage)
; ============================================
WarningThreshold=75
CriticalThreshold=90
