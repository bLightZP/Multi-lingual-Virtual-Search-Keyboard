unit VK_MultiLingualVirtualKeyboard;

{
  Delphi 7 compatible Multi-lingual Virtual Keyboard renderer for 32bit (RGBA) bitmaps.

  Key points:
  - Draws ONLY onto an existing 32bit TBitmap (background already prepared by caller).
  - Uses GDI+ to draw round-rects and Unicode text (Segoe UI Emoji) with anti-aliasing.
  - Separates rendering: DrawInputFieldArea() and DrawKeyboardArea() for partial redraw.
  - Supports all installed keyboard layouts, with a Globe key (??) when more than one is installed.
  - Virtual keys show glyphs generated via ToUnicodeEx() for current HKL.
  - Physical keyboard input and mouse clicks update the input field state.
  - Input field supports caret, quick 5-blink feedback on input, mouse caret positioning, selection.

  Dependencies:
  - Delphi 7
  - TNT Unicode units available in project (WideString/WideChar are native in Delphi 7).
  - GDI+ Delphi headers/objects (GDIPAPI, GDIPOBJ) available.
  - Windows 10+ assumed.

  Typical usage:
    1) Prepare a 32bit TBitmap (pf32bit) with your background drawn.
    2) Call VK.SetTargetBitmap(Bmp, BackgroundRGBA);
    3) Call VK.DrawKeyboardArea; VK.DrawInputFieldArea;
    4) Use Bmp as the source for a layered window update.

  Integration with form events:
    - OnMouseDown/Move/Up call VK.MouseDown/Move/Up
    - OnKeyDown call VK.KeyDown
    - OnKeyPress (Wide) call VK.WideKeyPress

  Notes:
    - This unit does NOT create windows/forms. It only renders and manages state.
    - Caller is responsible for re-drawing background portions before re-rendering overlays.
}

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Math, Clipbrd,
  GDIPAPI, GDIPOBJ;

const
  VK_OEM_COMMA  = $BC; // For any country/region, the Comma and Less Than key
  VK_OEM_PERIOD = $BE; // For any country/region, the Period and Greater Than key
  VK_OEM_2      = $BF; // It can vary by keyboard. For the US ANSI keyboard, the Forward Slash and Question Mark key

type
  TABCFLOAT = packed record
    abcfA: Single;
    abcfB: Single;
    abcfC: Single;
  end;

  TRGBAColor = packed record
    R, G, B, A: Byte;
  end;

  TVKPage = (vpLetters, vpSymbols1, vpSymbols2);

  TVKKeyKind = (
    kkChar,       // Inserts Output text
    kkBackspace,  // Deletes
    kkShift,      // Toggles shift
    kkSymbols,    // Toggles symbols page
    kkSpace,      // Inserts space
    kkSubmit,     // Submit/search action
    kkLang        // Switch keyboard layout HKL
  );

  // Focus model for keyboard navigation (input field vs key layout).
  TVKFocus = (
    vfInput,
    vfKeys
  );

  TVKKey = class
  public
    Kind   : TVKKeyKind;
    Vk     : UINT;        // used when Kind=kkChar and generated from VK mapping
    RectF  : TGPRectF;    // key rectangle in bitmap coords
    Weight : Single;      // relative width in row
    Text   : WideString;  // displayed caption
    Output : WideString;  // inserted text
  end;

  // Stable key "signature" used to preserve highlight across rebuilds.
  // This fixes the "Shift / Language / Symbols resets highlight to first key" issue.
  TVKKeySignature = packed record
    Kind   : TVKKeyKind;
    Vk     : UINT;
    Text   : WideString;
    Output : WideString;
  end;

  TVKOnSubmit = procedure(Sender: TObject; const Query: WideString) of object;
  TVKOnLayoutChanged = procedure(Sender: TObject; NewHKL: HKL) of object;
  TVKOnTextChanged = procedure(Sender: TObject; const NewText: WideString) of object;

  TVKRenderer = class
  private
    FBitmap: TBitmap;

    // Rectangles within the bitmap where UI is drawn
    FKeyLayoutRect: TRect;
    FInputRect: TRect;

    // Fractional layout parameters (relative to KeyLayoutRect size)
    FKeyMarginXFrac: Single;
    FKeyMarginYFrac: Single;
    FKeyPadXFrac: Single;
    FKeyPadYFrac: Single;

    // Input text margins (relative to InputRect size)
    FInputMarginXFrac: Single;
    FInputMarginYFrac: Single;

    // Round-rect corner radius fractions (default 0.25 of element height)
    FRadiusFracLayout: Single;
    FRadiusFracInput: Single;
    FRadiusFracKey: Single;

    // Colors (RGBA)
    FColLayoutBg: TRGBAColor;
    FColInputBg: TRGBAColor;
    FColInputBgInactive: TRGBAColor;
    FColKeyBg: TRGBAColor;
    FColInputFont: TRGBAColor;
    FColKeyFont: TRGBAColor;
    FColSelBg: TRGBAColor;
    FColSelFont: TRGBAColor;
    FCaretColor: TRGBAColor;

    // Target background color (used to pre-compose caches for SourceCopy blits).
    FTargetBg: TRGBAColor;

    // Cached round-rect bitmaps (performance)
    // Cached elements list:
    // 1) Key layout area background round-rect.
    // 2) Text input area background round-rect in both the focused and unfocused state.
    // 3) Key round-rect background for layouts with 4 lines in both the highlighted and default states.
    // 4) Key round-rect background for layouts with 5 lines in both the highlighted and default states.
    FCacheLayoutRR: TBitmap;
    FCacheInputRRFocused: TBitmap;
    FCacheInputRRUnfocused: TBitmap;
    FCacheKeyRR4Default: TBitmap;
    FCacheKeyRR4Focused: TBitmap;
    FCacheKeyRR5Default: TBitmap;
    FCacheKeyRR5Focused: TBitmap;

    // Cache metadata to rebuild only when required (rect sizes, colors, radii, margins)
    FCacheLayoutW, FCacheLayoutH: Integer;
    FCacheInputW, FCacheInputH: Integer;
    FCacheKeyW: Integer;
    FCacheKeyH4, FCacheKeyH5: Integer;
    FCacheLayoutCol: TRGBAColor;
    FCacheInputColFocused: TRGBAColor;
    FCacheInputColUnfocused: TRGBAColor;
    FCacheKeyColDefault: TRGBAColor;
    FCacheKeyColFocused: TRGBAColor;
    FCacheRadiusLayout: Single;
    FCacheRadiusInput: Single;
    FCacheRadiusKey: Single;
    FCacheKeyMarginYFrac: Single;

    // Cache base backgrounds (used to build caches deterministically for SourceCopy blits)
    FCacheLayoutBaseBg: TRGBAColor;
    FCacheInputBaseBg: TRGBAColor;
    FCacheKeyBaseBg: TRGBAColor;

    // State
    FPage: TVKPage;
    FShift: Boolean;

    // Installed layouts
    FHKLs: array of HKL;
    FHKLCount: Integer;

    // Key model
    FKeys: TList; // items: TVKKey
    FLayoutDirty: Boolean;

    FGDIPGraphics : TGPGraphics;

    // Cache GDI+ font, format, brushes across frames (keyboard)
    FKeyFont: TGPFont;
    FKeyFmt : TGPStringFormat;
    FKeyBrush : TGPSolidBrush;
    FKeyFontPxCache: Integer;
    FKeyFontColorCache: TRGBAColor;

    // Cache GDI+ font, format, brushes across frames (input)
    FInputFont: TGPFont;
    FInputFmt: TGPStringFormat;
    FInputBrushNormal: TGPSolidBrush;
    FInputBrushSel: TGPSolidBrush;
    FInputBrushSelBg: TGPSolidBrush;
    FInputFontPxCache: Integer;
    FInputFontColorCache: TRGBAColor;
    FInputSelFontColorCache: TRGBAColor;
    FInputSelBgColorCache: TRGBAColor;

    // Focus + currently highlighted key index for arrow navigation.
    FFocus: TVKFocus;
    FFocusedKeyIdx: Integer; // -1 when none

    FActiveKeyIndex : Integer;

    // Preserve highlighted key across rebuilds (Shift/Lang/Symbols cause rebuild).
    FPendingFocusSigValid: Boolean;
    FPendingFocusSig: TVKKeySignature;

    // Prevent KeyPress from stealing focus after handled KeyDown keys (fixes Enter twice issue).
    // In Delphi/VCL it is possible for KeyPress (#13) to fire even when KeyDown handled it.
    FSwallowNextKeyPress: Boolean;

    // Input field model
    FText: WideString;
    FCaretPos: Integer;      // 0..Length(FText)
    FSelAnchor: Integer;     // anchor used during mouse selection
    FSelStart: Integer;      // normalized selection start
    FSelLen: Integer;        // normalized selection length
    FMouseSelecting: Boolean;

    // Horizontal scroll of input text (pixels) to keep caret visible
    FScrollX: Single;

    // Caret blink: quick 5-blink feedback after input
    FCaretVisible: Boolean;
    FCaretBlinkStartTick: DWORD;
    FCaretBlinkTogglesLeft: Integer; // 10 toggles = 5 blinks
    FCaretLastToggleTick: DWORD;

    // Cached widths for caret mapping and selection rendering
    FWidthCacheValid: Boolean;
    FWidthCacheFontPx: Single;
    FCumWidth: array of Single; // [0..Len], cumulative pixel width

    // Events
    FOnSubmit: TVKOnSubmit;
    FOnLayoutChanged: TVKOnLayoutChanged;
    FOnTextChanged: TVKOnTextChanged;

  private
    class function RGBA(r, g, b, a: Byte): TRGBAColor;

    // GDI+ helpers
    class function GPColor(const C: TRGBAColor): TGPColor;
    class function RectToGPRectF(const R: TRect): TGPRectF;
    class function RectW(const R: TRect): Integer;
    class function RectH(const R: TRect): Integer;
    class function ClampI(Value, AMin, AMax: Integer): Integer;

    class function CreateRoundRectPath(const RF: TGPRectF; RadiusPx: Single): TGPGraphicsPath;

    // Cache helpers
    class function SameRGBA(const A, B: TRGBAColor): Boolean;
    class function BlendRGBA_Over(const Back, Fore: TRGBAColor): TRGBAColor;
    procedure FreeCaches;
    function  CalcKeyRowHeightPx(Rows: Integer): Integer;
    function  BuildRoundRectCache(W, H: Integer; RadiusFrac: Single; const UnderColor, BaseBgColor, FillColor: TRGBAColor; UseUnder : Boolean): TBitmap;
    procedure EnsureCaches; // rebuilds caches when size/color/radius/margins change

    // Text resources caching helpers
    procedure FreeTextResources;
    procedure EnsureKeyTextResources(FontPx: Integer);
    procedure EnsureInputTextResources(FontPx: Integer);

    function CurrentHKL: HKL;
    function HasMultipleLayouts: Boolean;
    procedure RefreshInstalledLayouts;

    // Keyboard build and layout
    procedure ClearKeys;
    procedure MarkLayoutDirty;
    procedure BuildKeysForCurrentState;
    procedure LayoutKeysIntoRect;
    procedure UpdateKeyCaptionsForHKL;

    // VK to Unicode
    function VkToUnicode(const Vk: UINT; ShiftDown: Boolean; Layout: HKL): WideString;

    // Hit testing
    function HitTestKey(X, Y: Integer): TVKKey;

    // Input editing helpers
    procedure NormalizeSelection;
    procedure ClearSelection;
    function HasSelection: Boolean;

    // Remove duplicate input measuring work (EnsureCaretInView no longer re-creates font/fmt)
    procedure EnsureCaretInView(G: TGPGraphics; FontPx: Single; Font: TGPFont; Fmt: TGPStringFormat);
    procedure NotifyInputActivity; // triggers 5-blink feedback

    // Width cache
    procedure RebuildWidthCache(G: TGPGraphics; FontPx: Single; Font: TGPFont; Fmt: TGPStringFormat);
    function XToCaretIndex(G: TGPGraphics; FontPx: Single; LocalX: Single): Integer;
    function CaretIndexToX(FontPx: Single; Index: Integer): Single;

    // Drawing pieces
    procedure DrawKey(G: TGPGraphics; Key: TVKKey; FontPx: Single; IsFocused: Boolean);

    // Clipboard helpers (Unicode safe) + input shortcuts.
    procedure ClipboardSetUnicodeText(const S: WideString);
    function ClipboardGetUnicodeText: WideString;
    procedure CopySelectionToClipboard;
    procedure CutSelectionToClipboard;
    procedure PasteFromClipboard;

    // Key focus navigation helpers (arrow navigation on the key layout).
    procedure SetFocus(AFocus: TVKFocus);
    function FirstVisibleKeyIndex: Integer;
    function AnyKeyHasLayout: Boolean;
    procedure EnsureFocusedKeyValid;
    function GetRowCount: Integer;
    procedure GetRowStartCount(Row: Integer; out StartIdx, Count: Integer);
    function GetKeyRowFromIndex(Index: Integer): Integer;
    function FindClosestKeyInRow(Row: Integer; RefCenterX: Single): Integer;
    procedure FocusKeyClosestToCaret;
    procedure MoveFocusedKeyUpDown(DeltaRow: Integer);
    procedure MoveFocusedKeyLeftRight(DeltaCol: Integer);

    // Highlight persistence across rebuilds.
    function MakeKeySignature(K: TVKKey): TVKKeySignature;
    function FindKeyBySignature(const Sig: TVKKeySignature): Integer;
    procedure RequestPreserveFocusedKey(K: TVKKey);
    procedure ApplyPendingFocusIfAny;

    // Unify mouse click and keyboard "Enter" activation.
    procedure ActivateKey(K: TVKKey);

  public
    constructor Create;
    destructor Destroy; override;

    // Initialization
    procedure SetTargetBitmap(ABitmap: TBitmap; const ABackground: TRGBAColor); // must be 32bit with alpha
    procedure SetKeyLayoutRect(const R: TRect);
    procedure SetInputRect(const R: TRect);

    // Layout parameters
    property KeyMarginXFrac: Single read FKeyMarginXFrac write FKeyMarginXFrac;
    property KeyMarginYFrac: Single read FKeyMarginYFrac write FKeyMarginYFrac;
    property KeyPadXFrac: Single read FKeyPadXFrac write FKeyPadXFrac;
    property KeyPadYFrac: Single read FKeyPadYFrac write FKeyPadYFrac;

    property InputMarginXFrac: Single read FInputMarginXFrac write FInputMarginXFrac;
    property InputMarginYFrac: Single read FInputMarginYFrac write FInputMarginYFrac;

    property RadiusFracLayout: Single read FRadiusFracLayout write FRadiusFracLayout;
    property RadiusFracInput: Single read FRadiusFracInput write FRadiusFracInput;
    property RadiusFracKey: Single read FRadiusFracKey write FRadiusFracKey;

    // Colors
    property ColLayoutBg: TRGBAColor read FColLayoutBg write FColLayoutBg;
    property ColInputBg: TRGBAColor read FColInputBg write FColInputBg;
    property ColKeyBg: TRGBAColor read FColKeyBg write FColKeyBg;
    property ColInputFont: TRGBAColor read FColInputFont write FColInputFont;
    property ColKeyFont: TRGBAColor read FColKeyFont write FColKeyFont;

    property ColSelBg: TRGBAColor read FColSelBg write FColSelBg;
    property ColSelFont: TRGBAColor read FColSelFont write FColSelFont;
    property CaretColor: TRGBAColor read FCaretColor write FCaretColor;
    property ColInputBgInactive: TRGBAColor read FColInputBgInactive write FColInputBgInactive;

    // Input access
    property Text: WideString read FText;
    property CaretPos: Integer read FCaretPos;
    property SelStart: Integer read FSelStart;
    property SelLen: Integer read FSelLen;

    // Expose focus read-only (optional utility for caller).
    property Focus: TVKFocus read FFocus;

    // Rendering (caller should redraw background area first)
    procedure DrawKeyboardArea;   // draws keyboard layout round-rect + keys
    procedure DrawInputFieldArea; // draws input field round-rect + text + selection + caret

    // Update caret blinking (call from a timer or your render loop)
    procedure TickCaretBlink;

    // Mouse integration
    procedure MouseDown(X, Y: Integer; Button: TMouseButton);
    procedure MouseMove(X, Y: Integer; Shift: TShiftState);
    procedure MouseUp(X, Y: Integer; Button: TMouseButton);

    // Keyboard integration (physical keyboard)
    procedure KeyDown(var Key: Word; Shift: TShiftState);
    procedure WideKeyPress(var Key: WideChar);

    // Optional events
    property OnSubmit: TVKOnSubmit read FOnSubmit write FOnSubmit;
    property OnLayoutChanged: TVKOnLayoutChanged read FOnLayoutChanged write FOnLayoutChanged;
    property OnTextChanged: TVKOnTextChanged read FOnTextChanged write FOnTextChanged;

    // Utility (direct editing)
    procedure SetSelection(StartIdx, Len: Integer);
    procedure ReplaceSelection(const S: WideString);
    procedure DeleteSelection;
    procedure SwitchToNextLayout;
  end;

  PHKL = ^HKL;

  function GetKeyboardLayoutListPtr(nBuff: Integer; lpList: PHKL): UINT; stdcall; external user32 name 'GetKeyboardLayoutList';
  function GetCharABCWidthsFloatW(hdc: HDC; iFirstChar, iLastChar: UINT; var lpABCF: TABCFLOAT): BOOL; stdcall; external 'gdi32.dll' name 'GetCharABCWidthsFloatW';
  procedure sFillRect32(DestBitmap : TBitmap; DestX,DestY,sWidth,sHeight : Integer; FillColor : DWord);

implementation

{ TVKRenderer helpers }

procedure sFillRect32(DestBitmap : TBitmap; DestX,DestY,sWidth,sHeight : Integer; FillColor : DWord);
type
  TMyScanLine32          = Array[0..32767] of TColor;
var
  X,Y     : Integer;
  PD32    : ^TMyScanLine32;
  PDDif   : Integer;
  PD32Src : ^TMyScanLine32;
  PDSize  : Integer;
  iWidth  : Integer;
  iHeight : Integer;
begin
  iWidth  := DestBitmap.Width;
  iHeight := DestBitmap.Height;

  If DestX+sWidth  > iWidth  then
    Dec(sWidth ,(DestX+sWidth) -iWidth);
  If DestY+sHeight > iHeight then
    Dec(sHeight,(DestY+sHeight)-iHeight);

  If (DestX >= 0) and (DestX+sWidth <= iWidth) and (DestY >= 0) and (DestY+sHeight <= iHeight) and (sHeight >= 1) and (sWidth >= 1) then
  Begin
    PD32  := DestBitmap.ScanLine[DestY];

    If sHeight >= 2 then
    Begin
      PDDif   := Integer(DestBitmap.ScanLine[DestY+1])-Integer(PD32);
      PD32Src := @PD32^;
      pdSize  := sWidth*4;

      For Y := 0 to sHeight-1 do
      Begin
        If Y = 0 then
        Begin
          For X := DestX to DestX+sWidth-1 do
            PD32^[X] := FillColor;
        End
          else
        Begin
          Move(PD32Src^[DestX],PD32^[DestX],pdSize);
        End;
        Inc(Integer(PD32),PDDif);
      End;
    End
      else
    Begin
      // Just one line
      For X := DestX to DestX+sWidth-1 do
        PD32^[X] := FillColor;
    End;
  End;
end;


procedure sCopyBitmap(SrcBitmap,DestBitmap : TCanvas; SrcX,SrcY,sWidth,sHeight,DestX,DestY : Integer);
begin
  BitBlt(DestBitmap.Handle,DestX,DestY,sWidth,sHeight,SrcBitmap.Handle,SrcX,SrcY,SRCCOPY);
end;


function UTF8StringToWideString(const S: UTF8String): WideString;
var
  SrcLen, DstLen: Integer;
  P: PAnsiChar;
begin
  SrcLen := Length(S);
  if SrcLen = 0 then
  begin
    Result := '';
    Exit;
  end;

  P := PAnsiChar(S);

  // Calculate required buffer size
  DstLen := MultiByteToWideChar(CP_UTF8, 0, P, SrcLen, nil, 0);
  if DstLen = 0 then
  begin
    // Handle invalid UTF-8 gracefully
    Result := '';
    Exit;
  end;

  SetLength(Result, DstLen);
  MultiByteToWideChar(CP_UTF8, 0, P, SrcLen, PWideChar(Result), DstLen);
end;

class function TVKRenderer.RGBA(r, g, b, a: Byte): TRGBAColor;
begin
  Result.R := r; Result.G := g; Result.B := b; Result.A := a;
end;

class function TVKRenderer.GPColor(const C: TRGBAColor): TGPColor;
begin
  Result := MakeColor(C.A, C.R, C.G, C.B);
end;

class function TVKRenderer.RectW(const R: TRect): Integer;
begin
  Result := R.Right - R.Left;
end;

class function TVKRenderer.RectH(const R: TRect): Integer;
begin
  Result := R.Bottom - R.Top;
end;

class function TVKRenderer.RectToGPRectF(const R: TRect): TGPRectF;
begin
  Result.X := R.Left;
  Result.Y := R.Top;
  Result.Width := RectW(R);
  Result.Height := RectH(R);
end;

class function TVKRenderer.ClampI(Value, AMin, AMax: Integer): Integer;
begin
  if Value < AMin then Result := AMin
  else if Value > AMax then Result := AMax
  else Result := Value;
end;

class function TVKRenderer.CreateRoundRectPath(const RF: TGPRectF; RadiusPx: Single): TGPGraphicsPath;
var
  D: Single;
begin
  Result := TGPGraphicsPath.Create;
  if (RF.Width <= 0) or (RF.Height <= 0) then Exit;

  D := RadiusPx * 2.0;
  if D > RF.Width then D := RF.Width;
  if D > RF.Height then D := RF.Height;

  if D <= 0 then
  begin
    Result.AddRectangle(RF);
    Exit;
  end;

  // Top-left
  Result.AddArc(RF.X, RF.Y, D, D, 180, 90);
  // Top-right
  Result.AddArc(RF.X + RF.Width - D, RF.Y, D, D, 270, 90);
  // Bottom-right
  Result.AddArc(RF.X + RF.Width - D, RF.Y + RF.Height - D, D, D, 0, 90);
  // Bottom-left
  Result.AddArc(RF.X, RF.Y + RF.Height - D, D, D, 90, 90);
  Result.CloseFigure;
end;


{ Cache helpers }

class function TVKRenderer.SameRGBA(const A, B: TRGBAColor): Boolean;
begin
  Result := (A.R = B.R) and (A.G = B.G) and (A.B = B.B) and (A.A = B.A);
end;

class function TVKRenderer.BlendRGBA_Over(const Back, Fore: TRGBAColor): TRGBAColor;
var
  AF, AB: Integer;
  OutA: Integer;
  BackMul: Integer;
  PR, PG, PB: Integer;
begin
  AF := Fore.A;
  AB := Back.A;

  // OutA = AF + AB*(1 - AF)
  OutA := AF + (AB * (255 - AF) + 127) div 255;
  if OutA < 0 then OutA := 0;
  if OutA > 255 then OutA := 255;

  if OutA = 0 then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Exit;
  end;

  // Back contribution in premultiplied space: AB*(1 - AF)
  BackMul := (AB * (255 - AF) + 127) div 255;

  // Premultiplied RGB sums
  PR := (Fore.R * AF) + (Back.R * BackMul);
  PG := (Fore.G * AF) + (Back.G * BackMul);
  PB := (Fore.B * AF) + (Back.B * BackMul);

  Result.A := Byte(OutA);
  Result.R := Byte((PR + (OutA div 2)) div OutA);
  Result.G := Byte((PG + (OutA div 2)) div OutA);
  Result.B := Byte((PB + (OutA div 2)) div OutA);
end;

procedure TVKRenderer.FreeCaches;
begin
  // Free cached round-rect bitmaps.
  if FCacheLayoutRR <> nil then FreeAndNil(FCacheLayoutRR);
  if FCacheInputRRFocused <> nil then FreeAndNil(FCacheInputRRFocused);
  if FCacheInputRRUnfocused <> nil then FreeAndNil(FCacheInputRRUnfocused);

  if FCacheKeyRR4Default <> nil then FreeAndNil(FCacheKeyRR4Default);
  if FCacheKeyRR4Focused <> nil then FreeAndNil(FCacheKeyRR4Focused);
  if FCacheKeyRR5Default <> nil then FreeAndNil(FCacheKeyRR5Default);
  if FCacheKeyRR5Focused <> nil then FreeAndNil(FCacheKeyRR5Focused);

  FCacheLayoutW := 0; FCacheLayoutH := 0;
  FCacheInputW := 0; FCacheInputH := 0;
  FCacheKeyW := 0;
  FCacheKeyH4 := 0; FCacheKeyH5 := 0;

  FillChar(FCacheLayoutCol, SizeOf(FCacheLayoutCol), 0);
  FillChar(FCacheInputColFocused, SizeOf(FCacheInputColFocused), 0);
  FillChar(FCacheInputColUnfocused, SizeOf(FCacheInputColUnfocused), 0);
  FillChar(FCacheKeyColDefault, SizeOf(FCacheKeyColDefault), 0);
  FillChar(FCacheKeyColFocused, SizeOf(FCacheKeyColFocused), 0);

  FCacheRadiusLayout := -1;
  FCacheRadiusInput := -1;
  FCacheRadiusKey := -1;
  FCacheKeyMarginYFrac := -1;

  // Reset cache base backgrounds.
  FillChar(FCacheLayoutBaseBg, SizeOf(FCacheLayoutBaseBg), 0);
  FillChar(FCacheInputBaseBg, SizeOf(FCacheInputBaseBg), 0);
  FillChar(FCacheKeyBaseBg, SizeOf(FCacheKeyBaseBg), 0);
end;

function TVKRenderer.CalcKeyRowHeightPx(Rows: Integer): Integer;
var
  H: Integer;
  MarginY: Single;
  RowH: Single;
begin
  Result := 0;
  if Rows <= 0 then Exit;

  H := RectH(FKeyLayoutRect);
  if H <= 0 then Exit;

  // Must match the same formula used by LayoutKeysIntoRect
  MarginY := Max(0, FKeyMarginYFrac) * H;
  RowH := (H - (MarginY * (Rows + 1))) / Rows;

  if RowH < 1 then RowH := 1;
  Result := Round(RowH);
  if Result < 1 then Result := 1;
end;


function TVKRenderer.BuildRoundRectCache(W, H: Integer; RadiusFrac: Single; const UnderColor, BaseBgColor, FillColor: TRGBAColor; UseUnder : Boolean): TBitmap;
var
  Bmp: TBitmap;
  G: TGPGraphics;
  RF: TGPRectF;
  RadiusPx: Single;
  P: TGPGraphicsPath;
  B: TGPSolidBrush;
begin
  Result := nil;
  if (W <= 0) or (H <= 0) then Exit;

  // Build cached round-rect
  // The cache is pre-composed so the final blit can use SourceCopy.
  Bmp := TBitmap.Create;
  Bmp.PixelFormat := pf32bit;
  Bmp.Width  := W;
  Bmp.Height := H;

  G := TGPGraphics.Create(Bmp.Canvas.Handle);
  try
    G.SetCompositingQuality(CompositingQualityHighQuality);

    If UseUnder = True then
    Begin
      sFillRect32(Bmp,0,0,W,H,GPColor(UnderColor));
      B := TGPSolidBrush.Create(GPColor(BaseBgColor));
      G.FillRectangle(B,0,0,W,H);
      B.Free;
    End
      else
    Begin
      sFillRect32(Bmp,0,0,W,H,GPColor(BaseBgColor));
    End;

    RF.X      := 0;
    RF.Y      := 0;
    RF.Width  := W-1;
    RF.Height := H-1;

    RadiusPx := Max(0, RadiusFrac) * RF.Height;

    P := CreateRoundRectPath(RF, RadiusPx);
    try
      B := TGPSolidBrush.Create(GPColor(FillColor));
      try
        G.FillPath(B, P);
      finally
        B.Free;
      end;
    finally
      P.Free;
    end;

  finally
    G.Free;
  end;

  Result := Bmp;
end;


procedure TVKRenderer.EnsureCaches;
var
  LW, LH: Integer;
  IW, IH: Integer;
  KW: Integer;
  KH4, KH5: Integer;
  NeedLayout, NeedInput, NeedKey: Boolean;
  HighlightCol: TRGBAColor;
  KeyBaseBg: TRGBAColor;
begin
  // Caches are rebuilt only when their effective parameters changed.
  // This keeps draw loops fast and avoids re-creating GDI+ paths per frame.

  LW := RectW(FKeyLayoutRect);
  LH := RectH(FKeyLayoutRect);

  IW := RectW(FInputRect);
  IH := RectH(FInputRect);

  // 1) Layout background cache
  NeedLayout :=
    (LW > 0) and (LH > 0) and
    ((FCacheLayoutRR = nil) or
     (FCacheLayoutW <> LW) or (FCacheLayoutH <> LH) or
     (not SameRGBA(FCacheLayoutCol, FColLayoutBg)) or
     (not SameRGBA(FCacheLayoutBaseBg, FTargetBg)) or
     (Abs(FCacheRadiusLayout - FRadiusFracLayout) > 0.00001));

  if NeedLayout then
  begin
    if FCacheLayoutRR <> nil then FreeAndNil(FCacheLayoutRR);
    FCacheLayoutRR := BuildRoundRectCache(LW, LH, FRadiusFracLayout, FTargetBg, FTargetBg, FColLayoutBg, False);

    FCacheLayoutW := LW;
    FCacheLayoutH := LH;
    FCacheLayoutCol := FColLayoutBg;
    FCacheLayoutBaseBg := FTargetBg;
    FCacheRadiusLayout := FRadiusFracLayout;
  end
  else if (LW <= 0) or (LH <= 0) then
  begin
    if FCacheLayoutRR <> nil then FreeAndNil(FCacheLayoutRR);
    FCacheLayoutW := 0;
    FCacheLayoutH := 0;
  end;

  // 2) Input background cache (focused + unfocused)
  NeedInput :=
    (IW > 0) and (IH > 0) and
    ((FCacheInputRRFocused = nil) or (FCacheInputRRUnfocused = nil) or
     (FCacheInputW <> IW) or (FCacheInputH <> IH) or
     (not SameRGBA(FCacheInputColFocused, FColInputBg)) or
     (not SameRGBA(FCacheInputColUnfocused, FColInputBgInactive)) or
     (not SameRGBA(FCacheInputBaseBg, FTargetBg)) or
     (Abs(FCacheRadiusInput - FRadiusFracInput) > 0.00001));

  if NeedInput then
  begin
    if FCacheInputRRFocused <> nil then FreeAndNil(FCacheInputRRFocused);
    if FCacheInputRRUnfocused <> nil then FreeAndNil(FCacheInputRRUnfocused);

    FCacheInputRRFocused   := BuildRoundRectCache(IW, IH, FRadiusFracInput, FTargetBg, FTargetBg, FColInputBg, False);
    FCacheInputRRUnfocused := BuildRoundRectCache(IW, IH, FRadiusFracInput, FTargetBg, FTargetBg, FColInputBgInactive, False);

    FCacheInputW := IW;
    FCacheInputH := IH;
    FCacheInputColFocused := FColInputBg;
    FCacheInputColUnfocused := FColInputBgInactive;
    FCacheInputBaseBg := FTargetBg;
    FCacheRadiusInput := FRadiusFracInput;
  end
  else if (IW <= 0) or (IH <= 0) then
  begin
    if FCacheInputRRFocused <> nil then FreeAndNil(FCacheInputRRFocused);
    if FCacheInputRRUnfocused <> nil then FreeAndNil(FCacheInputRRUnfocused);
    FCacheInputW := 0;
    FCacheInputH := 0;
  end;

  // 3) Key background caches (4 rows + 5 rows) in default + highlighted states
  // Width uses the key layout area width, height uses row height for 4/5 rows.
  KW := LW;
  KH4 := 0;
  KH5 := 0;
  if (KW > 0) and (LH > 0) then
  begin
    KH4 := CalcKeyRowHeightPx(4);
    KH5 := CalcKeyRowHeightPx(5);
  end;

  HighlightCol := RGBA(255, 0, 0, 255);

  // For keys, the base background is the target background blended with the layout round-rect color.
  // This matches the pixels already present inside the keyboard layout area after its cache is blitted.
  KeyBaseBg := BlendRGBA_Over(FTargetBg, FColLayoutBg);
  {KeyBaseBg.R := (FTargetBg.R+FColLayoutBg.R) div 2;
  KeyBaseBg.G := (FTargetBg.G+FColLayoutBg.G) div 2;
  KeyBaseBg.B := (FTargetBg.B+FColLayoutBg.B) div 2;
  KeyBaseBg.A := (FTargetBg.A+FColLayoutBg.A) div 2;}

  NeedKey :=
    (KW > 0) and (KH4 > 0) and (KH5 > 0) and
    ((FCacheKeyRR4Default = nil) or (FCacheKeyRR4Focused = nil) or
     (FCacheKeyRR5Default = nil) or (FCacheKeyRR5Focused = nil) or
     (FCacheKeyW <> KW) or
     (FCacheKeyH4 <> KH4) or (FCacheKeyH5 <> KH5) or
     (not SameRGBA(FCacheKeyColDefault, FColKeyBg)) or
     (not SameRGBA(FCacheKeyColFocused, HighlightCol)) or
     (not SameRGBA(FCacheKeyBaseBg, KeyBaseBg)) or
     (Abs(FCacheRadiusKey - FRadiusFracKey) > 0.00001) or
     (Abs(FCacheKeyMarginYFrac - FKeyMarginYFrac) > 0.00001));

  if NeedKey then
  begin
    if FCacheKeyRR4Default <> nil then FreeAndNil(FCacheKeyRR4Default);
    if FCacheKeyRR4Focused <> nil then FreeAndNil(FCacheKeyRR4Focused);
    if FCacheKeyRR5Default <> nil then FreeAndNil(FCacheKeyRR5Default);
    if FCacheKeyRR5Focused <> nil then FreeAndNil(FCacheKeyRR5Focused);

    // Key caches are "max width" (layout width). Per-key render uses 2 DrawImage calls:
    // - copy left portion (cropped to key width)
    // - patch right cap (cropped from cache right edge)
    // The cache is pre-composed so the final blit can use SourceCopy.
    FCacheKeyRR4Default := BuildRoundRectCache(KW, KH4, FRadiusFracKey, FTargetBg, FColLayoutBg, FColKeyBg, True);
    FCacheKeyRR4Focused := BuildRoundRectCache(KW, KH4, FRadiusFracKey, FTargetBg, FColLayoutBg, HighlightCol, True);

    FCacheKeyRR5Default := BuildRoundRectCache(KW, KH5, FRadiusFracKey, FTargetBg, FColLayoutBg, FColKeyBg, True);
    FCacheKeyRR5Focused := BuildRoundRectCache(KW, KH5, FRadiusFracKey, FTargetBg, FColLayoutBg, HighlightCol, True);

    FCacheKeyW  := KW;
    FCacheKeyH4 := KH4;
    FCacheKeyH5 := KH5;
    FCacheKeyColDefault := FColKeyBg;
    FCacheKeyColFocused := HighlightCol;
    FCacheKeyBaseBg := KeyBaseBg;
    FCacheRadiusKey := FRadiusFracKey;
    FCacheKeyMarginYFrac := FKeyMarginYFrac;
  end
  else if (KW <= 0) or (LH <= 0) then
  begin
    if FCacheKeyRR4Default <> nil then FreeAndNil(FCacheKeyRR4Default);
    if FCacheKeyRR4Focused <> nil then FreeAndNil(FCacheKeyRR4Focused);
    if FCacheKeyRR5Default <> nil then FreeAndNil(FCacheKeyRR5Default);
    if FCacheKeyRR5Focused <> nil then FreeAndNil(FCacheKeyRR5Focused);

    FCacheKeyW := 0;
    FCacheKeyH4 := 0;
    FCacheKeyH5 := 0;
  end;
end;


{ Text resources caching helpers }

procedure TVKRenderer.FreeTextResources;
begin
  // cached GDI+ font/format/brush resources.
  if FKeyBrush <> nil then FreeAndNil(FKeyBrush);
  if FKeyFmt <> nil then FreeAndNil(FKeyFmt);
  if FKeyFont <> nil then FreeAndNil(FKeyFont);
  FKeyFontPxCache := 0;
  FillChar(FKeyFontColorCache, SizeOf(FKeyFontColorCache), 0);

  if FInputBrushSelBg <> nil then FreeAndNil(FInputBrushSelBg);
  if FInputBrushSel <> nil then FreeAndNil(FInputBrushSel);
  if FInputBrushNormal <> nil then FreeAndNil(FInputBrushNormal);
  if FInputFmt <> nil then FreeAndNil(FInputFmt);
  if FInputFont <> nil then FreeAndNil(FInputFont);
  FInputFontPxCache := 0;
  FillChar(FInputFontColorCache, SizeOf(FInputFontColorCache), 0);
  FillChar(FInputSelFontColorCache, SizeOf(FInputSelFontColorCache), 0);
  FillChar(FInputSelBgColorCache, SizeOf(FInputSelBgColorCache), 0);
end;


procedure TVKRenderer.EnsureKeyTextResources(FontPx: Integer);
begin
  // Cache GDI+ font, format, brushes across frames (keyboard)
  if FontPx < 1 then FontPx := 1;

  if (FKeyFmt = nil) then
  begin
    FKeyFmt := TGPStringFormat.Create(TGPStringFormat.GenericTypographic);
    FKeyFmt.SetAlignment(StringAlignmentCenter);
    FKeyFmt.SetLineAlignment(StringAlignmentCenter);
    FKeyFmt.SetTrimming(StringTrimmingEllipsisCharacter);
    FKeyFmt.SetFormatFlags(StringFormatFlagsNoWrap);
  end;

  if (FKeyFont = nil) or (FKeyFontPxCache <> FontPx) then
  begin
    if FKeyFont <> nil then FreeAndNil(FKeyFont);
    FKeyFont := TGPFont.Create('Segoe UI Emoji', FontPx, FontStyleRegular, UnitPixel);
    FKeyFontPxCache := FontPx;
  end;

  if (FKeyBrush = nil) or (not SameRGBA(FKeyFontColorCache, FColKeyFont)) then
  begin
    if FKeyBrush <> nil then FreeAndNil(FKeyBrush);
    FKeyBrush := TGPSolidBrush.Create(GPColor(FColKeyFont));
    FKeyFontColorCache := FColKeyFont;
  end;
end;


procedure TVKRenderer.EnsureInputTextResources(FontPx: Integer);
begin
  // Cache GDI+ font, format, brushes across frames (input)
  if FontPx < 1 then FontPx := 1;

  if (FInputFmt = nil) then
  begin
    FInputFmt := TGPStringFormat.Create(TGPStringFormat.GenericTypographic);
    FInputFmt.SetAlignment(StringAlignmentNear);
    FInputFmt.SetLineAlignment(StringAlignmentCenter);
    FInputFmt.SetTrimming(StringTrimmingNone);
    FInputFmt.SetFormatFlags(StringFormatFlagsNoWrap or StringFormatFlagsMeasureTrailingSpaces);
  end;

  if (FInputFont = nil) or (FInputFontPxCache <> FontPx) then
  begin
    if FInputFont <> nil then FreeAndNil(FInputFont);
    FInputFont := TGPFont.Create('Segoe UI Emoji', FontPx, FontStyleRegular, UnitPixel);
    FInputFontPxCache := FontPx;
  end;

  if (FInputBrushNormal = nil) or (not SameRGBA(FInputFontColorCache, FColInputFont)) then
  begin
    if FInputBrushNormal <> nil then FreeAndNil(FInputBrushNormal);
    FInputBrushNormal := TGPSolidBrush.Create(GPColor(FColInputFont));
    FInputFontColorCache := FColInputFont;
  end;

  if (FInputBrushSel = nil) or (not SameRGBA(FInputSelFontColorCache, FColSelFont)) then
  begin
    if FInputBrushSel <> nil then FreeAndNil(FInputBrushSel);
    FInputBrushSel := TGPSolidBrush.Create(GPColor(FColSelFont));
    FInputSelFontColorCache := FColSelFont;
  end;

  if (FInputBrushSelBg = nil) or (not SameRGBA(FInputSelBgColorCache, FColSelBg)) then
  begin
    if FInputBrushSelBg <> nil then FreeAndNil(FInputBrushSelBg);
    FInputBrushSelBg := TGPSolidBrush.Create(GPColor(FColSelBg));
    FInputSelBgColorCache := FColSelBg;
  end;
end;


{ TVKRenderer }

constructor TVKRenderer.Create;
begin
  inherited Create;

  FKeys := TList.Create;

  // Default rects are empty until user sets them
  SetRectEmpty(FKeyLayoutRect);
  SetRectEmpty(FInputRect);

  // Default layout fractions (tuned for typical 1080p-ish UI)
  FKeyMarginXFrac   := 0.005;
  FKeyMarginYFrac   := 0.014;
  FKeyPadXFrac      := 0.020;
  FKeyPadYFrac      := 0.020;

  FInputMarginXFrac := 0.012;
  FInputMarginYFrac := 0.200;

  // Default radius fractions
  FRadiusFracLayout := 0.05;
  FRadiusFracInput  := 0.25;
  FRadiusFracKey    := 0.25;

  // Default colors
  FColLayoutBg        := RGBA(255, 0,   0,   128);
  FColInputBg         := RGBA(0,   0,   255, 128);
  FColInputBgInactive := RGBA(0,   0,   255, 48);
  FColInputFont       := RGBA(255, 255, 255, 255);
  FColKeyBg           := RGBA(128, 128, 128, 96);
  FColKeyFont         := RGBA(192, 255, 192, 255);
  FColSelBg           := RGBA(80, 140, 255, 160);
  FColSelFont         := RGBA(255, 255, 255, 255);
  FCaretColor         := RGBA(255, 192, 192, 192);

  // Default target background is "unknown" until SetTargetBitmap is called.
  FTargetBg           := RGBA(0, 0, 0, 0);

  FPage  := vpLetters;
  FShift := False;

  // Default focus starts in input field; no highlighted key yet.
  FFocus := vfInput;
  FFocusedKeyIdx := -1;
  FActiveKeyIndex := -1;

  // Highlight preservation defaults
  FPendingFocusSigValid := False;
  FillChar(FPendingFocusSig, SizeOf(FPendingFocusSig), 0);

  // KeyPress swallow flag
  FSwallowNextKeyPress := False;

  FText           := '';
  FCaretPos       := 0;
  FSelAnchor      := 0;
  FSelStart       := 0;
  FSelLen         := 0;
  FMouseSelecting := False;

  FScrollX := 0;

  FCaretVisible := True;
  FCaretBlinkStartTick := 0;
  FCaretBlinkTogglesLeft := 0;
  FCaretLastToggleTick := 0;

  FWidthCacheValid := False;
  FWidthCacheFontPx := 0;

  FBitmap := nil;
  FGDIPGraphics := nil;

  // Initialize cache metadata and cache handles
  FreeCaches;

  // Initialize cached text resources
  FKeyFont := nil;
  FKeyFmt := nil;
  FKeyBrush := nil;
  FKeyFontPxCache := 0;
  FillChar(FKeyFontColorCache, SizeOf(FKeyFontColorCache), 0);

  FInputFont := nil;
  FInputFmt := nil;
  FInputBrushNormal := nil;
  FInputBrushSel := nil;
  FInputBrushSelBg := nil;
  FInputFontPxCache := 0;
  FillChar(FInputFontColorCache, SizeOf(FInputFontColorCache), 0);
  FillChar(FInputSelFontColorCache, SizeOf(FInputSelFontColorCache), 0);
  FillChar(FInputSelBgColorCache, SizeOf(FInputSelBgColorCache), 0);

  RefreshInstalledLayouts;
  MarkLayoutDirty;
end;


destructor TVKRenderer.Destroy;
begin
  // Free cached GDI+ text resources.
  FreeTextResources;

  // Free cached round-rect bitmaps.
  FreeCaches;

  If FGDIPGraphics <> nil then
    FGDIPGraphics.Free;

  If (FBitmap <> nil) and (FBitmap.Canvas.LockCount > 0) then
    FBitmap.Canvas.Unlock;

  ClearKeys;
  FreeAndNil(FKeys);
  inherited Destroy;
end;


procedure TVKRenderer.SetTargetBitmap(ABitmap: TBitmap; const ABackground: TRGBAColor);
begin
  FBitmap := ABitmap;
  FBitmap.Canvas.Lock;

  FTargetBg := ABackground;

  FGDIPGraphics := TGPGraphics.Create(FBitmap.Canvas.Handle);

  // Cache sizes depend on rects, not bitmap, but caller typically sets bitmap before drawing.
  EnsureCaches;
end;


procedure TVKRenderer.SetKeyLayoutRect(const R: TRect);
begin
  FKeyLayoutRect := R;
  MarkLayoutDirty;

  // Layout and key caches depend on this rect.
  EnsureCaches;
end;


procedure TVKRenderer.SetInputRect(const R: TRect);
begin
  FInputRect := R;
  FWidthCacheValid := False;

  // Input caches depend on this rect.
  EnsureCaches;
end;


procedure TVKRenderer.RefreshInstalledLayouts;
var
  C, I: Integer;
begin
  C := GetKeyboardLayoutListPtr(0, nil);
  FHKLCount := 0;
  SetLength(FHKLs, 0);

  if C <= 0 then Exit;

  SetLength(FHKLs, C);

  // Delphi 7 GetKeyboardLayoutList import is "var List" and is not usable with dynamic arrays.
  // Use the pointer-based import for both count and fill.
  if GetKeyboardLayoutListPtr(C, @FHKLs[0]) = 0 then
  begin
    SetLength(FHKLs, 0);
    Exit;
  end;

  // Remove duplicates (rare, but can happen)
  // Keep order stable
  FHKLCount := 0;
  for I := 0 to C - 1 do
  begin
    if (FHKLCount = 0) or (FHKLs[FHKLCount - 1] <> FHKLs[I]) then
    begin
      FHKLs[FHKLCount] := FHKLs[I];
      Inc(FHKLCount);
    end;
  end;
  SetLength(FHKLs, FHKLCount);
end;


function TVKRenderer.HasMultipleLayouts: Boolean;
begin
  Result := FHKLCount > 1;
end;


function TVKRenderer.CurrentHKL: HKL;
begin
  Result := GetKeyboardLayout(0);
end;


procedure TVKRenderer.MarkLayoutDirty;
begin
  FLayoutDirty := True;
end;


procedure TVKRenderer.ClearKeys;
var
  I: Integer;
begin
  for I := 0 to FKeys.Count - 1 do
    TObject(FKeys[I]).Free;
  FKeys.Clear;
end;


function TVKRenderer.VkToUnicode(const Vk: UINT; ShiftDown: Boolean; Layout: HKL): WideString;
var
  KS: array[0..255] of Byte;
  Scan: UINT;
  Buf: array[0..7] of WideChar;
  Rc: Integer;
begin
  Result := '';
  FillChar(KS, SizeOf(KS), 0);
  if ShiftDown then KS[VK_SHIFT] := $80;

  Scan := MapVirtualKeyEx(Vk, 0, Layout);
  FillChar(Buf, SizeOf(Buf), 0);

  Rc := ToUnicodeEx(Vk, Scan, @KS, Buf, 8, 0, Layout);
  if Rc > 0 then
    SetString(Result, PWideChar(@Buf[0]), Rc)
  else
    Result := '';
end;


procedure TVKRenderer.BuildKeysForCurrentState;

  function NewKey(AKind: TVKKeyKind; AWeight: Single; const AText, AOut: WideString; AVk: UINT): TVKKey;
  begin
    Result         := TVKKey.Create;
    Result.Kind    := AKind;
    Result.Weight  := AWeight;
    Result.Text    := AText;
    Result.Output  := AOut;
    Result.Vk      := AVk;
    Result.RectF.X := 0; Result.RectF.Y := 0; Result.RectF.Width := 0; Result.RectF.Height := 0;
    FKeys.Add(Result);
  end;

var
  L: HKL;
  Multi: Boolean;

  procedure AddRowLettersDigits;
  begin
    // Digits row 1..0 + Backspace
    NewKey(kkChar, 1, '', '', Ord('1'));
    NewKey(kkChar, 1, '', '', Ord('2'));
    NewKey(kkChar, 1, '', '', Ord('3'));
    NewKey(kkChar, 1, '', '', Ord('4'));
    NewKey(kkChar, 1, '', '', Ord('5'));
    NewKey(kkChar, 1, '', '', Ord('6'));
    NewKey(kkChar, 1, '', '', Ord('7'));
    NewKey(kkChar, 1, '', '', Ord('8'));
    NewKey(kkChar, 1, '', '', Ord('9'));
    NewKey(kkChar, 1, '', '', Ord('0'));
    NewKey(kkBackspace, 1.3, WideString(#$232B), '', 0); // ?
  end;

  procedure AddRowQwerty;
  begin
    // Physical positions, glyph from HKL
    NewKey(kkChar, 1, '', '', Ord('Q'));
    NewKey(kkChar, 1, '', '', Ord('W'));
    NewKey(kkChar, 1, '', '', Ord('E'));
    NewKey(kkChar, 1, '', '', Ord('R'));
    NewKey(kkChar, 1, '', '', Ord('T'));
    NewKey(kkChar, 1, '', '', Ord('Y'));
    NewKey(kkChar, 1, '', '', Ord('U'));
    NewKey(kkChar, 1, '', '', Ord('I'));
    NewKey(kkChar, 1, '', '', Ord('O'));
    NewKey(kkChar, 1, '', '', Ord('P'));
  end;

  procedure AddRowAsdf;
  begin
    NewKey(kkChar, 1, '', '', Ord('A'));
    NewKey(kkChar, 1, '', '', Ord('S'));
    NewKey(kkChar, 1, '', '', Ord('D'));
    NewKey(kkChar, 1, '', '', Ord('F'));
    NewKey(kkChar, 1, '', '', Ord('G'));
    NewKey(kkChar, 1, '', '', Ord('H'));
    NewKey(kkChar, 1, '', '', Ord('J'));
    NewKey(kkChar, 1, '', '', Ord('K'));
    NewKey(kkChar, 1, '', '', Ord('L'));
  end;

  procedure AddRowZxc;
  begin
    NewKey(kkShift, 1.5, UTF8StringToWideString(#$e2#$87#$a7), '', 0);
    NewKey(kkChar, 1, '', '', Ord('Z'));
    NewKey(kkChar, 1, '', '', Ord('X'));
    NewKey(kkChar, 1, '', '', Ord('C'));
    NewKey(kkChar, 1, '', '', Ord('V'));
    NewKey(kkChar, 1, '', '', Ord('B'));
    NewKey(kkChar, 1, '', '', Ord('N'));
    NewKey(kkChar, 1, '', '', Ord('M'));
    NewKey(kkChar, 1, '', '', VK_OEM_COMMA);
    NewKey(kkChar, 1, '', '', VK_OEM_PERIOD);
    NewKey(kkChar, 1, '', '', VK_OEM_2); // /?
  end;

  procedure AddRowBottomLetters;
  begin
    Multi := HasMultipleLayouts;
    if Multi then
      NewKey(kkLang, 1.2, UTF8StringToWideString(#$f0#$9f#$8c#$90), '', 0); // Globe

    NewKey(kkSymbols, 1.2, WideString('123'), '', 0);
    NewKey(kkSpace, 4.0, WideString(''), WideString(' '), 0);

    NewKey(kkSubmit, 1.6, UTF8StringToWideString(#$e2#$a4#$b7), '', 0); // Enter
  end;

  procedure AddSymbolsPage1;
  begin
    // Page 1: common search symbols, plus digits
    NewKey(kkChar, 1, '1', '1', 0);
    NewKey(kkChar, 1, '2', '2', 0);
    NewKey(kkChar, 1, '3', '3', 0);
    NewKey(kkChar, 1, '4', '4', 0);
    NewKey(kkChar, 1, '5', '5', 0);
    NewKey(kkChar, 1, '6', '6', 0);
    NewKey(kkChar, 1, '7', '7', 0);
    NewKey(kkChar, 1, '8', '8', 0);
    NewKey(kkChar, 1, '9', '9', 0);
    NewKey(kkChar, 1, '0', '0', 0);
    NewKey(kkBackspace, 1.3, WideString(#$232B), '', 0);

    NewKey(kkChar, 1, '@', '@', 0);
    NewKey(kkChar, 1, '#', '#', 0);
    NewKey(kkChar, 1, '$', '$', 0);
    NewKey(kkChar, 1, '&', '&', 0);
    NewKey(kkChar, 1, '-', '-', 0);
    NewKey(kkChar, 1, '_', '_', 0);
    NewKey(kkChar, 1, '+', '+', 0);
    NewKey(kkChar, 1, '(', '(', 0);
    NewKey(kkChar, 1, ')', ')', 0);
    NewKey(kkChar, 1, '/', '/', 0);

    NewKey(kkChar, 1, '*', '*', 0);
    NewKey(kkChar, 1, '"', '"', 0);
    NewKey(kkChar, 1, '''', '''', 0);
    NewKey(kkChar, 1, ':', ':', 0);
    NewKey(kkChar, 1, ';', ';', 0);
    NewKey(kkChar, 1, '!', '!', 0);
    NewKey(kkChar, 1, '?', '?', 0);
    NewKey(kkChar, 1, '%', '%', 0);
    NewKey(kkChar, 1, '=', '=', 0);
    NewKey(kkChar, 1, '.', '.', 0);

    // Bottom
    Multi := HasMultipleLayouts;
    if Multi then
      NewKey(kkLang, 1.2, UTF8StringToWideString(#$f0#$9f#$8c#$90), '', 0);

    NewKey(kkSymbols, 1.2, WideString('ABC'), '', 0);
    NewKey(kkChar, 1.2, WideString('#+='), '', 0); // toggles to symbols2 via handler (see click)
    NewKey(kkSpace, 3.6, WideString(''), WideString(' '), 0);
    NewKey(kkSubmit, 1.6, UTF8StringToWideString(#$e2#$a4#$b7), '', 0);
  end;

  procedure AddSymbolsPage2;
  begin
    // Page 2: additional punctuation
    NewKey(kkChar, 1, '[', '[', 0);
    NewKey(kkChar, 1, ']', ']', 0);
    NewKey(kkChar, 1, '{', '{', 0);
    NewKey(kkChar, 1, '}', '}', 0);
    NewKey(kkChar, 1, '<', '<', 0);
    NewKey(kkChar, 1, '>', '>', 0);
    NewKey(kkChar, 1, '^', '^', 0);
    NewKey(kkChar, 1, '~', '~', 0);
    NewKey(kkChar, 1, '`', '`', 0);
    NewKey(kkChar, 1, '|', '|', 0);
    NewKey(kkBackspace, 1.3, WideString(#$232B), '', 0);

    NewKey(kkChar, 1, '\', '\', 0);
    NewKey(kkChar, 1, ',', ',', 0);
    NewKey(kkChar, 1, '.', '.', 0);
    NewKey(kkChar, 1, '?', '?', 0);
    NewKey(kkChar, 1, '!', '!', 0);
    NewKey(kkChar, 1, '·', WideString(#$00B7), 0);
    NewKey(kkChar, 1, '°', WideString(#$00B0), 0);
    NewKey(kkChar, 1, '©', WideString(#$00A9), 0);
    NewKey(kkChar, 1, '®', WideString(#$00AE), 0);
    NewKey(kkChar, 1, '€', WideString(#$20AC), 0);

    NewKey(kkChar, 1, '£', WideString(#$00A3), 0);
    NewKey(kkChar, 1, '¥', WideString(#$00A5), 0);
    NewKey(kkChar, 1, '¢', WideString(#$00A2), 0);
    NewKey(kkChar, 1, '§', WideString(#$00A7), 0);
    NewKey(kkChar, 1, '×', WideString(#$00D7), 0);
    NewKey(kkChar, 1, '÷', WideString(#$00F7), 0);
    NewKey(kkChar, 1, '…', WideString(#$2026), 0);
    NewKey(kkChar, 1, '“', WideString(#$201C), 0);
    NewKey(kkChar, 1, '”', WideString(#$201D), 0);
    NewKey(kkChar, 1, '’', WideString(#$2019), 0);

    Multi := HasMultipleLayouts;
    if Multi then
      NewKey(kkLang, 1.2, UTF8StringToWideString(#$f0#$9f#$8c#$90), '', 0);

    NewKey(kkSymbols, 1.2, WideString('ABC'), '', 0);
    NewKey(kkChar, 1.2, WideString('123'), '', 0); // toggles to symbols1 via handler
    NewKey(kkSpace, 3.6, WideString(''), WideString(' '), 0);
    NewKey(kkSubmit, 1.6, UTF8StringToWideString(#$e2#$a4#$b7), '', 0);
  end;

begin
  ClearKeys;

  L := CurrentHKL;

  case FPage of
    vpLetters:
      begin
        AddRowLettersDigits;
        AddRowQwerty;
        AddRowAsdf;
        AddRowZxc;
        AddRowBottomLetters;
      end;
    vpSymbols1:
      AddSymbolsPage1;
    vpSymbols2:
      AddSymbolsPage2;
  end;

  UpdateKeyCaptionsForHKL; // fills Text/Output for VK-derived char keys
  FLayoutDirty := False;

  // Do NOT call EnsureFocusedKeyValid here based on RectF sizes.
  // At this stage keys have RectF = 0 and validation would incorrectly reset focus to first key.
  // Focus validation and applying the preserved signature is performed AFTER LayoutKeysIntoRect.
end;


procedure TVKRenderer.UpdateKeyCaptionsForHKL;
var
  I: Integer;
  K: TVKKey;
  L: HKL;
  S: WideString;
begin
  L := CurrentHKL;

  for I := 0 to FKeys.Count - 1 do
  begin
    K := TVKKey(FKeys[I]);

    if (K.Kind = kkChar) and (K.Vk <> 0) and (K.Text = '') then
    begin
      // VK-derived keys (letters/digits/OEM) in vpLetters
      S := VkToUnicode(K.Vk, FShift, L);

      // Fallback: show VK name if mapping failed
      if S = '' then
      begin
        if (K.Vk >= Ord('A')) and (K.Vk <= Ord('Z')) then
          S := WideString(WideChar(K.Vk))
        else if (K.Vk >= Ord('0')) and (K.Vk <= Ord('9')) then
          S := WideString(WideChar(K.Vk))
        else
          S := '?';
      end;

      K.Text := S;
      K.Output := S;
    end;
  end;
end;


procedure TVKRenderer.LayoutKeysIntoRect;
var
  R: TRect;
  W, H: Integer;
  MarginX, MarginY: Single;

  procedure LayoutRow(var Index: Integer; KeyCountInRow: Integer; TopY: Single; RowH: Single);
  var
    I: Integer;
    TotalWeight, X, AvailW, KeyW: Single;
    K: TVKKey;
  begin
    if KeyCountInRow <= 0 then Exit;

    TotalWeight := 0;
    for I := 0 to KeyCountInRow - 1 do
      TotalWeight := TotalWeight + TVKKey(FKeys[Index + I]).Weight;

    AvailW := W - (MarginX * (KeyCountInRow + 1));
    if AvailW <= 0 then AvailW := 0;

    X := R.Left + MarginX;

    for I := 0 to KeyCountInRow - 1 do
    begin
      K := TVKKey(FKeys[Index + I]);
      if TotalWeight > 0 then KeyW := AvailW * (K.Weight / TotalWeight) else KeyW := 0;

      K.RectF.X := X;
      K.RectF.Y := TopY;
      K.RectF.Width := KeyW;
      K.RectF.Height := RowH;

      X := X + KeyW + MarginX;
    end;

    Inc(Index, KeyCountInRow);
  end;

var
  Idx: Integer;
  Rows, RowI, RowH: Integer;
  CurY: Single;

begin
  R := FKeyLayoutRect;
  W := RectW(R);
  H := RectH(R);

  if (W <= 0) or (H <= 0) then Exit;
  if FKeys.Count = 0 then Exit;

  // Margins in pixels (fraction of layout size)
  MarginX := Max(0, FKeyMarginXFrac) * W;
  MarginY := Max(0, FKeyMarginYFrac) * H;

  // Decide rows based on page and key model:
  // vpLetters has 5 rows (11,10,9,11, up to 4 keys bottom depending on multi layout)
  // vpSymbols pages are 4 rows (11,10,10,4 or 5)
  if FPage = vpLetters then Rows := 5 else Rows := 4;

  RowH := Round((H - (MarginY * (Rows + 1))) / Rows);
  if RowH < 0 then RowH := 0;

  CurY := R.Top + MarginY;
  Idx := 0;

  if FPage = vpLetters then
  begin
    LayoutRow(Idx, 11, CurY, RowH); CurY := CurY + RowH + MarginY;
    LayoutRow(Idx, 10, CurY, RowH); CurY := CurY + RowH + MarginY;
    LayoutRow(Idx,  9, CurY, RowH); CurY := CurY + RowH + MarginY;
    LayoutRow(Idx, 11, CurY, RowH); CurY := CurY + RowH + MarginY;

    // Bottom: either 4 keys or 3 keys (no ??)
    if HasMultipleLayouts then
      LayoutRow(Idx, 4, CurY, RowH)
    else
      LayoutRow(Idx, 3, CurY, RowH);
  end
  else
  begin
    // Symbols: 11 keys row 1
    LayoutRow(Idx, 11, CurY, RowH); CurY := CurY + RowH + MarginY;
    LayoutRow(Idx, 10, CurY, RowH); CurY := CurY + RowH + MarginY;
    LayoutRow(Idx, 10, CurY, RowH); CurY := CurY + RowH + MarginY;

    // Bottom: depending on multi layout, row count differs
    if HasMultipleLayouts then
      LayoutRow(Idx, 5, CurY, RowH)
    else
      LayoutRow(Idx, 4, CurY, RowH);
  end;

  // Any remaining keys (safety): set to zero-size so they won't draw
  for RowI := Idx to FKeys.Count - 1 do
  begin
    TVKKey(FKeys[RowI]).RectF.Width := 0;
    TVKKey(FKeys[RowI]).RectF.Height := 0;
  end;

  // Apply the preserved focus signature now that keys have real RectF sizes.
  // This keeps the highlight on the key that caused a rebuild (Shift/Lang/Symbols),
  // instead of snapping to the first key.
  ApplyPendingFocusIfAny;

  // Validate focus now that layout exists.
  EnsureFocusedKeyValid;
end;


procedure TVKRenderer.DrawKey(G: TGPGraphics; Key: TVKKey; FontPx: Single; IsFocused: Boolean);
var
  RF: TGPRectF;
  TxtRect: TGPRectF;
  PadX, PadY: Single;
  DX, DY, DW, DH: Integer;
  CacheBmp: TBitmap;
  CacheW, CacheH: Integer;
  Rows: Integer;
  CapW: Single;
  CapWi, LeftWi: Integer;
  DestRect: TGPRectF;
  SrcW: Single;
  Dst: TGPRectF;
begin
  RF := Key.RectF;
  if (RF.Width <= 0) or (RF.Height <= 0) then Exit;

  // Use cached key round-rect background.
  // The cache is "max width" (layout width). Rendering requires only 2 DrawImage calls per key:
  // 1) Draw the left portion cropped to key width-cap
  // 2) Patch the right cap from the cache right edge
  Rows := GetRowCount;
  CacheBmp := nil;

  if Rows = 5 then
  begin
    if IsFocused then
      CacheBmp := FCacheKeyRR5Focused else
      CacheBmp := FCacheKeyRR5Default;
    CacheH := FCacheKeyH5;
  end
  else
  begin
    if IsFocused then
      CacheBmp := FCacheKeyRR4Focused else
      CacheBmp := FCacheKeyRR4Default;
    CacheH := FCacheKeyH4;
  end;

  CacheW := FCacheKeyW;

  if (CacheBmp <> nil) and (CacheW > 0) and (CacheH > 0) then
  begin
    // Snap destination to pixels to avoid sampling transparent border
    DX := Round(RF.X);
    DY := Round(RF.Y);
    DW := Round(RF.Width);
    DH := Round(RF.Height);
    if DW < 1 then Exit;
    if DH < 1 then Exit;

    // Integer cap width
    CapWi := Round((FRadiusFracKey * DH * 2.0) + 2.0);
    if CapWi < 4 then CapWi := 4;
    if CapWi > DW then CapWi := DW;

    LeftWi := DW - CapWi;

    // Left part
    if LeftWi > 0 then
    begin
      Dst.X := DX;
      Dst.Y := DY;
      Dst.Width := LeftWi;
      Dst.Height := DH;
      sCopyBitmap(CacheBmp.Canvas,FBitmap.Canvas,0,0,LeftWi,DH,DX,DY);
    end;

    // Right cap
    Dst.X := DX + LeftWi;
    Dst.Y := DY;
    Dst.Width := CapWi;
    Dst.Height := DH;
    sCopyBitmap(CacheBmp.Canvas,FBitmap.Canvas,CacheBmp.Width-CapWi,0,CapWi,DH,DX+LeftWi,DY);
  end;

  // Text padding relative to KeyLayoutRect
  PadX := Max(0, FKeyPadXFrac) * RectW(FKeyLayoutRect);
  PadY := Max(0, FKeyPadYFrac) * RectH(FKeyLayoutRect);

  TxtRect.X      := RF.X + PadX;
  TxtRect.Y      := RF.Y + PadY;
  TxtRect.Width  := Max(0, RF.Width - PadX * 2);
  TxtRect.Height := Max(0, RF.Height - PadY * 2);

  if (TxtRect.Width <= 0) or (TxtRect.Height <= 0) then Exit;

  // Center text inside key
  G.DrawString(Key.Text, Length(Key.Text), FKeyFont, TxtRect, FKeyFmt, FKeyBrush);
end;


procedure TVKRenderer.DrawKeyboardArea;
var
  LayoutRF: TGPRectF;
  KeyFontPx: Integer;
  I: Integer;
  K: TVKKey;
  DestRect: TGPRectF;
begin
  if (FBitmap = nil) then Exit;
  if (RectW(FKeyLayoutRect) <= 0) or (RectH(FKeyLayoutRect) <= 0) then Exit;

  // IMPORTANT: Caller should redraw the background bitmap portion here before drawing overlays.
  // Example: RedrawBackgroundArea(FKeyLayoutRect);

  if FLayoutDirty then
  begin
    BuildKeysForCurrentState;
    LayoutKeysIntoRect;
  end;

  EnsureFocusedKeyValid;

  // Ensure cached round-rect bitmaps exist before drawing.
  EnsureCaches;

  FGDIPGraphics.SetSmoothingMode(SmoothingModeAntiAlias);
  FGDIPGraphics.SetCompositingQuality(CompositingQualityHighQuality);
  FGDIPGraphics.SetTextRenderingHint(TextRenderingHintAntiAlias);

  LayoutRF := RectToGPRectF(FKeyLayoutRect);

  // Draw cached key layout background round-rect.
  if (FCacheLayoutRR <> nil) and (FCacheLayoutW > 0) and (FCacheLayoutH > 0) then
  begin
    DestRect := LayoutRF;

    // Fast blit of cached round-rect bitmap using SourceCopy.
    sCopyBitmap(FCacheLayoutRR.Canvas,FBitmap.Canvas,0,0,FCacheLayoutW,FCacheLayoutH,Trunc(DestRect.X),Trunc(DestRect.Y));
  end;

  // Key font size scaled by key height
  KeyFontPx := Round(Max(8, LayoutRF.Height * 0.10));

  // Cache GDI+ font/format/brush across frames.
  EnsureKeyTextResources(KeyFontPx);

  for I := 0 to FKeys.Count - 1 do
  begin
    K := FKeys[I];
    if (K.RectF.Width > 0) and (K.RectF.Height > 0) then
      DrawKey(FGDIPGraphics, K, KeyFontPx, (FFocus = vfKeys) and (I = FFocusedKeyIdx));
  end;
end;


procedure TVKRenderer.RebuildWidthCache(G: TGPGraphics; FontPx: Single; Font: TGPFont; Fmt: TGPStringFormat);
const
  MAX_RANGES = 32;
var
  L, ChunkStart, ChunkCount, I, Pos1: Integer;
  Layout: TGPRectF;
  CR: array[0..MAX_RANGES-1] of TCharacterRange;
  Regions: array[0..MAX_RANGES-1] of TGPRegion;
  B: TGPRectF;

  SF: TGPStringFormat;

  DC: HDC;
  LF: TLogFontW;
  HF, OldFont: HFONT;

  Ch: WideChar;
  ABCF: TABCFLOAT;
  AVal, AdvVal: Single;

  Origin: array of Single;      // 1..L
  LastRightInk: Single;
  LastAdvance: Single;
begin
  L := Length(FText);
  SetLength(FCumWidth, L + 1);
  FCumWidth[0] := 0;

  if L = 0 then
  begin
    FWidthCacheValid := True;
    FWidthCacheFontPx := FontPx;
    Exit;
  end;

  FontPx := Round(FontPx);

  Layout.X := 0;
  Layout.Y := 0;
  Layout.Width := 32000;
  Layout.Height := FontPx * 4;

  SetLength(Origin, L + 1);
  LastRightInk := 0;
  LastAdvance := 0;

  // HFONT for ABC metrics (must match face + pixel height)
  DC := FBitmap.Canvas.Handle;
  FillChar(LF, SizeOf(LF), 0);
  LF.lfHeight := -Round(FontPx);
  LF.lfWeight := FW_NORMAL;
  LF.lfCharSet := DEFAULT_CHARSET;
  LF.lfOutPrecision := OUT_TT_PRECIS;
  LF.lfClipPrecision := CLIP_DEFAULT_PRECIS;
  LF.lfQuality := ANTIALIASED_QUALITY;
  LF.lfPitchAndFamily := DEFAULT_PITCH;
  lstrcpyW(LF.lfFaceName, 'Segoe UI Emoji');

  HF := CreateFontIndirectW(LF);
  OldFont := SelectObject(DC, HF);
  try
    // Use typographic format for measuring ranges
    SF := TGPStringFormat.Create(TGPStringFormat.GenericTypographic);
    try
      SF.SetTrimming(StringTrimmingNone);
      SF.SetFormatFlags(SF.GetFormatFlags or
        StringFormatFlagsNoWrap or
        StringFormatFlagsMeasureTrailingSpaces);

      ChunkStart := 0;
      while ChunkStart < L do
      begin
        ChunkCount := L - ChunkStart;
        if ChunkCount > MAX_RANGES then
          ChunkCount := MAX_RANGES;

        for I := 0 to ChunkCount - 1 do
        begin
          CR[I].First := ChunkStart + I;  // 0-based index into UTF-16
          CR[I].Length := 1;
          Regions[I] := TGPRegion.Create;
        end;

        SF.SetMeasurableCharacterRanges(ChunkCount, @CR[0]);
        G.MeasureCharacterRanges(FText, L, Font, Layout, SF, ChunkCount, Regions[0]);

        for I := 0 to ChunkCount - 1 do
        begin
          Pos1 := ChunkStart + I + 1;     // 1-based for FText indexing
          Ch := FText[Pos1];

          Regions[I].GetBounds(B, G);     // B.X is left ink bound in layout coords

          // Get ABC A to convert ink-left to origin:
          // inkLeft = origin + A  => origin = inkLeft - A
          AVal := 0;
          AdvVal := 0;
          if GetCharABCWidthsFloatW(DC, Ord(Ch), Ord(Ch), ABCF) then
          begin
            AVal := ABCF.abcfA;
            AdvVal := ABCF.abcfA + ABCF.abcfB + ABCF.abcfC;
            if AdvVal < 0 then AdvVal := 0;
          end;

          Origin[Pos1] := B.X - AVal;

          if Pos1 = L then
          begin
            LastRightInk := B.X + B.Width;  // keep ink-right for end caret
            LastAdvance := AdvVal;
          end;

          Regions[I].Free;
        end;

        Inc(ChunkStart, ChunkCount);
      end;

    finally
      SF.Free;
    end;

  finally
    SelectObject(DC, OldFont);
    DeleteObject(HF);
  end;

  // Build caret insertion points:
  // FCumWidth[i] = caret after i characters (between i and i+1)
  FCumWidth[0] := 0;

  // caret after i chars equals origin of char (i+1)
  for I := 1 to L - 1 do
    FCumWidth[I] := Origin[I + 1];

  // end caret: use insertion point, but never left of last ink-right
  FCumWidth[L] := Origin[L] + LastAdvance;
  if FCumWidth[L] < LastRightInk then
    FCumWidth[L] := LastRightInk;

  // Ensure monotonic (defensive)
  for I := 1 to L do
    if FCumWidth[I] < FCumWidth[I - 1] then
      FCumWidth[I] := FCumWidth[I - 1];

  FWidthCacheValid := True;
  FWidthCacheFontPx := FontPx;
end;


function TVKRenderer.CaretIndexToX(FontPx: Single; Index: Integer): Single;
begin
  if not FWidthCacheValid then
  begin
    Result := 0;
    Exit;
  end;

  Index := ClampI(Index, 0, Length(FText));
  Result := FCumWidth[Index];
end;


function TVKRenderer.XToCaretIndex(G: TGPGraphics; FontPx: Single; LocalX: Single): Integer;
var
  L, Lo, Hi, Mid: Integer;
begin
  L := Length(FText);

  if (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01) then
  begin
    // Will be rebuilt by caller before use in normal flow
    Result := 0;
    Exit;
  end;

  // Binary search in cumulative widths
  Lo := 0;
  Hi := L;

  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FCumWidth[Mid] < LocalX then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;

  // Decide closer of Lo and Lo-1
  if (Lo > 0) and (Lo <= L) then
  begin
    if Abs(FCumWidth[Lo] - LocalX) > Abs(FCumWidth[Lo - 1] - LocalX) then
      Dec(Lo);
  end;

  Result := ClampI(Lo, 0, L);
end;


procedure TVKRenderer.NormalizeSelection;
var
  A, B: Integer;
begin
  A := ClampI(FSelAnchor, 0, Length(FText));
  B := ClampI(FCaretPos, 0, Length(FText));

  if A <= B then
  begin
    FSelStart := A;
    FSelLen := B - A;
  end
    else
  begin
    FSelStart := B;
    FSelLen := A - B;
  end;
end;


procedure TVKRenderer.ClearSelection;
begin
  FSelAnchor := FCaretPos;
  FSelStart := FCaretPos;
  FSelLen := 0;
end;


function TVKRenderer.HasSelection: Boolean;
begin
  Result := FSelLen > 0;
end;


procedure TVKRenderer.DeleteSelection;
begin
  if not HasSelection then Exit;
  Delete(FText, FSelStart + 1, FSelLen);
  FCaretPos := FSelStart;
  ClearSelection;
  FWidthCacheValid := False;
  if Assigned(FOnTextChanged) then FOnTextChanged(Self, FText);
end;


procedure TVKRenderer.ReplaceSelection(const S: WideString);
begin
  if HasSelection then
    DeleteSelection;

  if S <> '' then
  begin
    Insert(S, FText, FCaretPos + 1);
    Inc(FCaretPos, Length(S));
    ClearSelection;
    FWidthCacheValid := False;
    if Assigned(FOnTextChanged) then FOnTextChanged(Self, FText);
    NotifyInputActivity;
  end;
end;


procedure TVKRenderer.SetSelection(StartIdx, Len: Integer);
begin
  StartIdx := ClampI(StartIdx, 0, Length(FText));
  Len := ClampI(Len, 0, Length(FText) - StartIdx);

  FSelStart := StartIdx;
  FSelLen := Len;
  FCaretPos := StartIdx + Len;
  FSelAnchor := StartIdx;
end;


procedure TVKRenderer.NotifyInputActivity;
begin
  // 5 blinks: 10 toggles (visible/hidden)
  FCaretBlinkStartTick := GetTickCount;
  FCaretLastToggleTick := FCaretBlinkStartTick;
  FCaretBlinkTogglesLeft := 10;
  FCaretVisible := True;
end;


procedure TVKRenderer.TickCaretBlink;
const
  FAST_TOGGLE_MS = 90;
begin
  if FCaretBlinkTogglesLeft <= 0 then Exit;

  if GetTickCount - FCaretLastToggleTick >= FAST_TOGGLE_MS then
  begin
    FCaretVisible := not FCaretVisible;
    Dec(FCaretBlinkTogglesLeft);
    FCaretLastToggleTick := GetTickCount;

    if FCaretBlinkTogglesLeft <= 0 then
      FCaretVisible := True; // settle visible
  end;
end;


procedure TVKRenderer.EnsureCaretInView(G: TGPGraphics; FontPx: Single; Font: TGPFont; Fmt: TGPStringFormat);
var
  InputRF: TGPRectF;
  TextAreaW: Single;
  MarginX: Single;
  CaretX: Single;
  DesiredLeft, DesiredRight: Single;
begin
  if (RectW(FInputRect) <= 0) or (RectH(FInputRect) <= 0) then Exit;

  InputRF := RectToGPRectF(FInputRect);
  MarginX := Max(0, FInputMarginXFrac) * InputRF.Width;

  TextAreaW := Max(0, InputRF.Width - MarginX * 2);
  if TextAreaW <= 0 then Exit;

  FontPx := Round(FontPx);

  if (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01) then
  begin
    if (G = nil) or (Font = nil) or (Fmt = nil) then Exit;
    RebuildWidthCache(G, FontPx, Font, Fmt);
  end;

  CaretX := CaretIndexToX(FontPx, FCaretPos);

  // keep caret within [FScrollX .. FScrollX + TextAreaW] with small internal padding
  DesiredLeft := FScrollX + 8;
  DesiredRight := FScrollX + TextAreaW - 8;

  if CaretX < DesiredLeft then
    FScrollX := Max(0, CaretX - 8)
  else if CaretX > DesiredRight then
    FScrollX := Max(0, CaretX - (TextAreaW - 8));
  FScrollX := Round(FScrollX);
end;


procedure TVKRenderer.DrawInputFieldArea;
var
  InputRF: TGPRectF;
  FontPx: Integer;
  MarginX, MarginY: Single;
  ClipRect: TGPRectF;

  // Selection drawing
  X0, X1, X2: Single;
  SelA, SelB: Integer;
  SelRF: TGPRectF;

  // Caret
  CaretX: Single;
  Pen: TGPPen;
  CaretTop, CaretBottom: Single;

  function SubStr0Based(const S: WideString; StartIdx, Count: Integer): WideString;
  begin
    // StartIdx is 0-based for our state, but Delphi Copy is 1-based
    if Count <= 0 then
      Result := ''
    else
      Result := Copy(S, StartIdx + 1, Count);
  end;

var
  LeftText, SelText, RightText: WideString;
  L: Integer;
  TextX: Single;
  TextRect: TGPRectF;
  DestRect: TGPRectF;
begin
  if (FBitmap = nil) then Exit;
  if (RectW(FInputRect) <= 0) or (RectH(FInputRect) <= 0) then Exit;

  // IMPORTANT: Caller should redraw the background bitmap portion here before drawing overlays.
  // Example: RedrawBackgroundArea(FInputRect);

  // Ensure cached input round-rects exist before drawing.
  EnsureCaches;

  FGDIPGraphics.SetSmoothingMode(SmoothingModeAntiAlias);
  FGDIPGraphics.SetCompositingQuality(CompositingQualityHighQuality);
  FGDIPGraphics.SetTextRenderingHint(TextRenderingHintAntiAlias);

  InputRF := RectToGPRectF(FInputRect);

  // Draw cached input background (focused/unfocused)
  DestRect := InputRF;

  // Fast blit of cached round-rect bitmap using SourceCopy.
  FGDIPGraphics.SetCompositingMode(CompositingModeSourceCopy);

  if FFocus = vfInput then
  begin
    if (FCacheInputRRFocused <> nil) and (FCacheInputW > 0) and (FCacheInputH > 0) then
      sCopyBitmap(FCacheInputRRFocused.Canvas,FBitmap.Canvas,0,0,Trunc(DestRect.Width),Trunc(DestRect.Height),Trunc(DestRect.X),Trunc(DestRect.Y));
  end
    else
  begin
    if (FCacheInputRRUnfocused <> nil) and (FCacheInputW > 0) and (FCacheInputH > 0) then
      sCopyBitmap(FCacheInputRRUnfocused.Canvas,FBitmap.Canvas,0,0,Trunc(DestRect.Width),Trunc(DestRect.Height),Trunc(DestRect.X),Trunc(DestRect.Y));
  end;

  // Restore blending for selection/text/caret.
  FGDIPGraphics.SetCompositingMode(CompositingModeSourceOver);

  MarginX := Max(0, FInputMarginXFrac) * InputRF.Width;
  MarginY := Max(0, FInputMarginYFrac) * InputRF.Height;

  // Font size scaled for clarity within field
  FontPx := Round(Max(10, InputRF.Height * 0.48));

  // Cache GDI+ font/format/brush across frames (input)
  EnsureInputTextResources(FontPx);

  // Clip to input field inner area
  ClipRect.X := InputRF.X + MarginX;
  ClipRect.Y := InputRF.Y + MarginY * 0.1;
  ClipRect.Width := Max(0, InputRF.Width - MarginX * 2);
  ClipRect.Height := Max(0, InputRF.Height - MarginY * 0.2);

  if (ClipRect.Width <= 0) or (ClipRect.Height <= 0) then Exit;

  FGDIPGraphics.SetClip(ClipRect);

  // Ensure caret is visible by adjusting horizontal scroll
  EnsureCaretInView(FGDIPGraphics, FontPx, FInputFont, FInputFmt);

  // Cache widths for selection/caret positioning
  if (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01) then
    RebuildWidthCache(FGDIPGraphics, FontPx, FInputFont, FInputFmt);

  TextX := Round(ClipRect.X - FScrollX);
  TextRect.X := TextX;
  TextRect.Y := ClipRect.Y;
  TextRect.Width := 10000; // wide, clipped anyway
  TextRect.Height := ClipRect.Height;

  // Selection background + draw segmented text
  L := Length(FText);

  if HasSelection then
  begin
    SelA := FSelStart;
    SelB := FSelStart + FSelLen;

    X0 := TextX + CaretIndexToX(FontPx, 0);
    X1 := TextX + CaretIndexToX(FontPx, SelA);
    X2 := TextX + CaretIndexToX(FontPx, SelB);

    // Selection background rectangle
    SelRF.X := X1;
    //SelRF.Y := ClipRect.Y + 2;
    SelRF.Y := ClipRect.Y + ClipRect.Height * 0.20;
    SelRF.Width := Max(0, X2 - X1);
    //SelRF.Height := Max(0, ClipRect.Height - 4);
    SelRF.Height := ClipRect.Height*0.60; 


    if (SelRF.Width > 0) and (SelRF.Height > 0) then
    begin
      // Fill selection background
      // avoid leaking brush created for selection fill
      if FInputBrushSelBg <> nil then
        FGDIPGraphics.FillRectangle(FInputBrushSelBg, SelRF);
    end;

    LeftText := SubStr0Based(FText, 0, SelA);
    SelText := SubStr0Based(FText, SelA, FSelLen);
    RightText := SubStr0Based(FText, SelB, L - SelB);

    // Draw left
    if LeftText <> '' then
    begin
      TextRect.X := TextX;
      FGDIPGraphics.DrawString(PWideChar(LeftText), Length(LeftText), FInputFont, TextRect, FInputFmt, FInputBrushNormal);
    end;

    // Draw selected
    if SelText <> '' then
    begin
      TextRect.X := TextX + CaretIndexToX(FontPx, SelA);
      FGDIPGraphics.DrawString(PWideChar(SelText), Length(SelText), FInputFont, TextRect, FInputFmt, FInputBrushSel);
    end;

    // Draw right
    if RightText <> '' then
    begin
      TextRect.X := TextX + CaretIndexToX(FontPx, SelB);
      FGDIPGraphics.DrawString(PWideChar(RightText), Length(RightText), FInputFont, TextRect, FInputFmt, FInputBrushNormal);
    end;
  end
    else
  begin
    // No selection: draw all text once
    if FText <> '' then
      FGDIPGraphics.DrawString(PWideChar(FText), Length(FText), FInputFont, TextRect, FInputFmt, FInputBrushNormal);
  end;

  // Caret
  if (FCaretVisible = True) then
  begin
    CaretX := TextX + CaretIndexToX(FontPx, FCaretPos);
    CaretX := Round(CaretX);

    CaretTop := ClipRect.Y + ClipRect.Height * 0.20;
    CaretBottom := ClipRect.Y + ClipRect.Height * 0.80;

    Pen := TGPPen.Create(GPColor(FCaretColor), 1.6);
    try
      FGDIPGraphics.DrawLine(Pen, CaretX, CaretTop, CaretX, CaretBottom);
    finally
      Pen.Free;
    end;
  end;

  // Remove clip
  FGDIPGraphics.ResetClip;
end;


function TVKRenderer.HitTestKey(X, Y: Integer): TVKKey;
var
  I: Integer;
  K: TVKKey;
begin
  Result := nil;
  for I := 0 to FKeys.Count - 1 do
  begin
    K := TVKKey(FKeys[I]);
    if (K.RectF.Width <= 0) or (K.RectF.Height <= 0) then Continue;

    if (X >= K.RectF.X) and (X < K.RectF.X + K.RectF.Width) and
       (Y >= K.RectF.Y) and (Y < K.RectF.Y + K.RectF.Height) then
    begin
      Result := K;
      Exit;
    end;
  end;
end;


procedure TVKRenderer.SwitchToNextLayout;
var
  Cur: HKL;
  I, NextI: Integer;
begin
  RefreshInstalledLayouts;
  if FHKLCount <= 1 then Exit;

  Cur := CurrentHKL;
  NextI := 0;

  for I := 0 to FHKLCount - 1 do
  begin
    if FHKLs[I] = Cur then
    begin
      NextI := (I + 1) mod FHKLCount;
      Break;
    end;
  end;

  ActivateKeyboardLayout(FHKLs[NextI], 0);

  // Layout glyphs change, redraw keyboard
  MarkLayoutDirty;
  if Assigned(FOnLayoutChanged) then
    FOnLayoutChanged(Self, FHKLs[NextI]);
end;


procedure TVKRenderer.MouseDown(X, Y: Integer; Button: TMouseButton);
var
  FontPx: Integer;
  InputRF: TGPRectF;
  MarginX: Single;
  LocalX: Single;
  K: TVKKey;
  KIdx: Integer;
begin
  if Button <> mbLeft then Exit;
  if (FBitmap = nil) then Exit;

  // Input field click?
  if PtInRect(FInputRect, Point(X, Y)) then
  begin
    // mouse click sets focus to input.
    SetFocus(vfInput);

    InputRF := RectToGPRectF(FInputRect);
    MarginX := Max(0, FInputMarginXFrac) * InputRF.Width;
    FontPx := Round(Max(10, InputRF.Height * 0.48));

    // Cache font/fmt/brushes across frames (no per-click object churn).
    EnsureInputTextResources(FontPx);

    // Ensure widths exist for caret mapping (create TGPGraphics only if measuring is required).
    if (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01) then
    begin
      RebuildWidthCache(FGDIPGraphics, FontPx, FInputFont, FInputFmt);
    end;

    // Convert mouse X to local text X (account margins + scroll)
    LocalX := (X - (FInputRect.Left + MarginX)) + FScrollX;

    FCaretPos := XToCaretIndex(nil, FontPx, LocalX);
    FSelAnchor := FCaretPos;
    NormalizeSelection; // zero selection
    FMouseSelecting := True;

    Exit;
  end;

  // Keyboard area click?
  if PtInRect(FKeyLayoutRect, Point(X, Y)) then
  begin
    if FLayoutDirty then
    begin
      BuildKeysForCurrentState;
      LayoutKeysIntoRect;
    end;

    K := HitTestKey(X, Y);
    if K = nil then Exit;

    // Mouse click sets focus to key layout and highlights clicked key.
    SetFocus(vfKeys);
    KIdx := FKeys.IndexOf(K);
    if KIdx >= 0 then
    begin
      FFocusedKeyIdx := KIdx;
      FActiveKeyIndex := FFocusedKeyIdx;
    end;

    ActivateKey(K);
    Exit;
  end;
end;

procedure TVKRenderer.MouseMove(X, Y: Integer; Shift: TShiftState);
var
  FontPx: Integer;
  InputRF: TGPRectF;
  MarginX: Single;
  LocalX: Single;
begin
  if not FMouseSelecting then Exit;
  if (FBitmap = nil) then Exit;
  if not PtInRect(FInputRect, Point(X, Y)) then Exit;

  // selection implies input focus.
  SetFocus(vfInput);

  InputRF := RectToGPRectF(FInputRect);
  MarginX := Max(0, FInputMarginXFrac) * InputRF.Width;
  FontPx := Round(Max(10, InputRF.Height * 0.48));

  // Cache font/fmt/brushes across frames (no per-move object churn).
  EnsureInputTextResources(FontPx);

  // Ensure widths exist for caret mapping. MouseMove is hot, so only create TGPGraphics if needed.
  if (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01) then
  begin
    RebuildWidthCache(FGDIPGraphics, FontPx, FInputFont, FInputFmt);
  end;

  LocalX := (X - (FInputRect.Left + MarginX)) + FScrollX;

  FCaretPos := XToCaretIndex(nil, FontPx, LocalX);
  NormalizeSelection;
end;

procedure TVKRenderer.MouseUp(X, Y: Integer; Button: TMouseButton);
begin
  if Button <> mbLeft then Exit;
  FMouseSelecting := False;
end;

procedure TVKRenderer.KeyDown(var Key: Word; Shift: TShiftState);
var
  ExtendSel: Boolean;
begin
  // Ctrl shortcuts for the input area:
  // - Ctrl+A select all
  // - Ctrl+C copy
  // - Ctrl+X cut
  // - Ctrl+V paste
  if (FFocus = vfInput) and (ssCtrl in Shift) then
  begin
    case Key of
      Ord('A'):
        begin
          SetSelection(0, Length(FText));
          Key := 0;
          Exit;
        end;
      Ord('C'):
        begin
          CopySelectionToClipboard;
          Key := 0;
          Exit;
        end;
      Ord('X'):
        begin
          CutSelectionToClipboard;
          Key := 0;
          Exit;
        end;
      Ord('V'):
        begin
          PasteFromClipboard;
          Key := 0;
          Exit;
        end;
    end;
  end;

  // Focus-aware arrow navigation
  // - If input has focus: Up/Down moves focus to key layout and highlights the visually closest key to the caret.
  // - If keys have focus: arrows move highlighted key; Up/Down returns to input when on top/bottom row.
  if FFocus = vfKeys then
  begin
    case Key of
      VK_LEFT:
        begin
          MoveFocusedKeyLeftRight(-1);
          Key := 0;
          Exit;
        end;
      VK_RIGHT:
        begin
          MoveFocusedKeyLeftRight(1);
          Key := 0;
          Exit;
        end;
      VK_UP:
        begin
          MoveFocusedKeyUpDown(-1);
          Key := 0;
          Exit;
        end;
      VK_DOWN:
        begin
          MoveFocusedKeyUpDown(1);
          Key := 0;
          Exit;
        end;
      VK_RETURN:
        begin
          // Fix "Enter twice removes highlight":
          // Some VCL paths still generate KeyPress (#13) after KeyDown handling.
          // We swallow the next WideKeyPress so it cannot switch focus to input.
          FSwallowNextKeyPress := True;

          EnsureFocusedKeyValid;
          if (FFocusedKeyIdx >= 0) and (FFocusedKeyIdx < FKeys.Count) then
            ActivateKey(TVKKey(FKeys[FFocusedKeyIdx]));

          Key := 0;
          Exit;
        end;
      VK_ESCAPE:
        begin
          FSwallowNextKeyPress := True;
          SetFocus(vfInput);
          Key := 0;
          Exit;
        end;
    end;

    Exit;
  end;

  // Editing keys (physical keyboard)
  ExtendSel := (ssShift in Shift);

  case Key of
    VK_TAB: // Tab is intercepted before it reaches here, switching fields using tabs is not working
      begin
        if FFocus = vfInput then
        begin
          // switch to key layout without losing the "active" key
          FFocus := vfKeys;

          if (FActiveKeyIndex >= 0) and (FActiveKeyIndex < FKeys.Count) then
            FFocusedKeyIdx := FActiveKeyIndex
          else
          begin
            // fallback only if there was never an active key yet
            // use your existing "closest key to caret" pick logic here
            FFocusedKeyIdx := 1;
            FActiveKeyIndex := FFocusedKeyIdx;
          end;
        end
        else
        begin
          // switch back to input, remove highlight but keep the active key remembered
          FFocus := vfInput;
          FFocusedKeyIdx := -1; // hide highlight only, do NOT change FActiveKeyIndex
        end;

        Key := 0;
      end;

    VK_UP, VK_DOWN:
      begin
        // Switch focus to key layout and pick the key closest to the caret.
        SetFocus(vfKeys);

        if FLayoutDirty then
        begin
          BuildKeysForCurrentState;
          LayoutKeysIntoRect;
        end;

        FocusKeyClosestToCaret;
        Key := 0;
      end;

    VK_LEFT:
      begin
        if (not ExtendSel) and HasSelection then
        begin
          // Collapse selection to start
          FCaretPos := FSelStart;
          ClearSelection;
          Key := 0;
          Exit;
        end;

        if ExtendSel and (not HasSelection) then
          FSelAnchor := FCaretPos;

        if FCaretPos > 0 then Dec(FCaretPos);

        if ExtendSel then
          NormalizeSelection
        else
          ClearSelection;

        Key := 0;
      end;

    VK_RIGHT:
      begin
        if (not ExtendSel) and HasSelection then
        begin
          // Collapse selection to end
          FCaretPos := FSelStart + FSelLen;
          ClearSelection;
          Key := 0;
          Exit;
        end;

        if ExtendSel and (not HasSelection) then
          FSelAnchor := FCaretPos;

        if FCaretPos < Length(FText) then Inc(FCaretPos);

        if ExtendSel then
          NormalizeSelection
        else
          ClearSelection;

        Key := 0;
      end;

    VK_HOME:
      begin
        if ExtendSel and (not HasSelection) then
          FSelAnchor := FCaretPos;

        FCaretPos := 0;

        if ExtendSel then
          NormalizeSelection
        else
          ClearSelection;

        Key := 0;
      end;

    VK_END:
      begin
        if ExtendSel and (not HasSelection) then
          FSelAnchor := FCaretPos;

        FCaretPos := Length(FText);

        if ExtendSel then
          NormalizeSelection
        else
          ClearSelection;

        Key := 0;
      end;

    VK_BACK:
      begin
        if HasSelection then
          DeleteSelection
        else if FCaretPos > 0 then
        begin
          Delete(FText, FCaretPos, 1);
          Dec(FCaretPos);
          ClearSelection;
          FWidthCacheValid := False;
          if Assigned(FOnTextChanged) then FOnTextChanged(Self, FText);
          NotifyInputActivity;
        end;
        Key := 0;
      end;

    VK_DELETE:
      begin
        if HasSelection then
          DeleteSelection
        else if FCaretPos < Length(FText) then
        begin
          Delete(FText, FCaretPos + 1, 1);
          ClearSelection;
          FWidthCacheValid := False;
          if Assigned(FOnTextChanged) then FOnTextChanged(Self, FText);
          NotifyInputActivity;
        end;
        Key := 0;
      end;

    VK_RETURN:
      begin
        if Assigned(FOnSubmit) then
          FOnSubmit(Self, FText);
        Key := 0;
      end;
  end;
end;

procedure TVKRenderer.WideKeyPress(var Key: WideChar);
begin
  if Key = #0 then Exit;

  // Fix "Enter twice removes highlight":
  // If KeyDown handled a key and we marked to swallow KeyPress, do it here.
  if FSwallowNextKeyPress then
  begin
    FSwallowNextKeyPress := False;
    Key := #0;
    Exit;
  end;

  // Do NOT switch focus to input for control characters.
  // Previously SetFocus(vfInput) happened before this check and could steal focus on #13.
  if Ord(Key) < 32 then
  begin
    Key := #0;
    Exit;
  end;

  // Printable input via physical keyboard (TTNTForm OnKeyPress gives WideChar)
  // any typing switches focus back to input.
  SetFocus(vfInput);

  ReplaceSelection(WideString(Key));
  Key := #0;
end;

{ Clipboard helpers (Unicode safe) }

procedure TVKRenderer.ClipboardSetUnicodeText(const S: WideString);
var
  hMem: HGLOBAL;
  pMem: PWideChar;
  Bytes: Integer;
begin
  if not OpenClipboard(0) then Exit;
  try
    EmptyClipboard;

    Bytes := (Length(S) + 1) * SizeOf(WideChar);
    hMem := GlobalAlloc(GMEM_MOVEABLE or GMEM_DDESHARE, Bytes);
    if hMem = 0 then Exit;

    pMem := GlobalLock(hMem);
    if pMem = nil then
    begin
      GlobalFree(hMem);
      Exit;
    end;

    try
      Move(PWideChar(S)^, pMem^, Bytes);
    finally
      GlobalUnlock(hMem);
    end;

    SetClipboardData(CF_UNICODETEXT, hMem);
    // Do not free hMem after SetClipboardData success.
  finally
    CloseClipboard;
  end;
end;


function TVKRenderer.ClipboardGetUnicodeText: WideString;
var
  hData: THandle;
  pMem: PWideChar;
begin
  Result := '';

  if not OpenClipboard(0) then Exit;
  try
    hData := GetClipboardData(CF_UNICODETEXT);
    if hData = 0 then Exit;

    pMem := GlobalLock(hData);
    if pMem = nil then Exit;
    try
      Result := WideString(pMem);
    finally
      GlobalUnlock(hData);
    end;
  finally
    CloseClipboard;
  end;
end;


procedure TVKRenderer.CopySelectionToClipboard;
var
  S: WideString;
begin
  if not HasSelection then Exit;
  S := Copy(FText, FSelStart + 1, FSelLen);
  ClipboardSetUnicodeText(S);
end;


procedure TVKRenderer.CutSelectionToClipboard;
begin
  if not HasSelection then Exit;
  CopySelectionToClipboard;
  DeleteSelection;
end;


procedure TVKRenderer.PasteFromClipboard;
var
  S: WideString;
begin
  S := ClipboardGetUnicodeText;

  // Sanity checks
  if S = '' then Exit;
  if Length(S) > 50 then
    S := Copy(S, 1, 50);
  if (Pos(#13, S) > 0) or (Pos(#10, S) > 0) then Exit;

  ReplaceSelection(S);
end;


{ Focus + key navigation helpers }

procedure TVKRenderer.SetFocus(AFocus: TVKFocus);
begin
  FFocus := AFocus;
  if FFocus = vfInput then
  begin
    // Keep caret visible when returning to input.
    FCaretVisible := True;
  end
  else
  begin
    EnsureFocusedKeyValid;
  end;
end;


function TVKRenderer.AnyKeyHasLayout: Boolean;
var
  I: Integer;
  K: TVKKey;
begin
  Result := False;
  for I := 0 to FKeys.Count - 1 do
  begin
    K := TVKKey(FKeys[I]);
    if (K.RectF.Width > 0) and (K.RectF.Height > 0) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;


function TVKRenderer.FirstVisibleKeyIndex: Integer;
var
  I: Integer;
  K: TVKKey;
begin
  Result := -1;
  for I := 0 to FKeys.Count - 1 do
  begin
    K := TVKKey(FKeys[I]);
    if (K.RectF.Width > 0) and (K.RectF.Height > 0) then
    begin
      Result := I;
      Exit;
    end;
  end;
end;


procedure TVKRenderer.EnsureFocusedKeyValid;
var
  FirstIdx: Integer;
begin
  if FFocus <> vfKeys then Exit;

  if FKeys.Count <= 0 then
  begin
    FFocusedKeyIdx := -1;
    Exit;
  end;

  // If keys are not laid out yet (RectF still 0), do not reset focus to "first visible".
  // We only clamp to range and wait for LayoutKeysIntoRect to apply preserved focus.
  if (FFocusedKeyIdx < 0) or (FFocusedKeyIdx >= FKeys.Count) then
  begin
    FFocusedKeyIdx := 0;
    FActiveKeyIndex := FFocusedKeyIdx;
  end;

  if not AnyKeyHasLayout then
    Exit;

  // Now that layout exists, ensure we are on a visible key
  if (TVKKey(FKeys[FFocusedKeyIdx]).RectF.Width <= 0) or
     (TVKKey(FKeys[FFocusedKeyIdx]).RectF.Height <= 0) then
  begin
    FirstIdx := FirstVisibleKeyIndex;
    if FirstIdx >= 0 then
    begin
      FFocusedKeyIdx := FirstIdx;
      FActiveKeyIndex := FFocusedKeyIdx;
    end;
  end;
end;


function TVKRenderer.GetRowCount: Integer;
begin
  if FPage = vpLetters then
    Result := 5
  else
    Result := 4;
end;


procedure TVKRenderer.GetRowStartCount(Row: Integer; out StartIdx, Count: Integer);
var
  Counts: array[0..4] of Integer;
  I, Rows: Integer;
begin
  Rows := GetRowCount;

  FillChar(Counts, SizeOf(Counts), 0);

  if FPage = vpLetters then
  begin
    Counts[0] := 11;
    Counts[1] := 10;
    Counts[2] := 9;
    Counts[3] := 11;
    if HasMultipleLayouts then
      Counts[4] := 4
    else
      Counts[4] := 3;
  end
    else
  begin
    Counts[0] := 11;
    Counts[1] := 10;
    Counts[2] := 10;
    if HasMultipleLayouts then
      Counts[3] := 5
    else
      Counts[3] := 4;
  end;

  if Row < 0 then Row := 0;
  if Row >= Rows then Row := Rows - 1;

  StartIdx := 0;
  for I := 0 to Row - 1 do
    Inc(StartIdx, Counts[I]);

  Count := Counts[Row];
end;


function TVKRenderer.GetKeyRowFromIndex(Index: Integer): Integer;
var
  Row, Rows, StartIdx, Cnt: Integer;
begin
  Rows := GetRowCount;
  Result := 0;

  for Row := 0 to Rows - 1 do
  begin
    GetRowStartCount(Row, StartIdx, Cnt);
    if (Index >= StartIdx) and (Index < StartIdx + Cnt) then
    begin
      Result := Row;
      Exit;
    end;
  end;

  Result := Rows - 1;
end;


function TVKRenderer.FindClosestKeyInRow(Row: Integer; RefCenterX: Single): Integer;
var
  StartIdx, Cnt, I: Integer;
  K: TVKKey;
  Cx: Single;
  BestIdx: Integer;
  BestD: Single;
  D: Single;
begin
  Result := -1;
  GetRowStartCount(Row, StartIdx, Cnt);
  if Cnt <= 0 then Exit;

  BestIdx := -1;
  BestD := 1.0e30;

  for I := 0 to Cnt - 1 do
  begin
    K := TVKKey(FKeys[StartIdx + I]);
    if (K.RectF.Width <= 0) or (K.RectF.Height <= 0) then Continue;

    Cx := K.RectF.X + (K.RectF.Width * 0.5);
    D := Abs(Cx - RefCenterX);

    if D < BestD then
    begin
      BestD := D;
      BestIdx := StartIdx + I;
    end;
  end;

  Result := BestIdx;
end;


procedure TVKRenderer.FocusKeyClosestToCaret;
var
  InputRF: TGPRectF;
  FontPx: Integer;
  MarginX, MarginY: Single;
  ClipRect: TGPRectF;
  CaretScreenX, CaretScreenY: Single;
  I: Integer;
  K: TVKKey;
  Kcx, Kcy: Single;
  Dx, Dy: Double;
  Dist: Double;
  BestIdx: Integer;
  BestDist: Double;
  NeedMeasure: Boolean;
begin
  EnsureFocusedKeyValid;

  if (FBitmap = nil) then Exit;
  if (FKeys.Count = 0) then Exit;

  if FLayoutDirty then
  begin
    BuildKeysForCurrentState;
    LayoutKeysIntoRect;
  end;

  InputRF := RectToGPRectF(FInputRect);
  MarginX := Max(0, FInputMarginXFrac) * InputRF.Width;
  MarginY := Max(0, FInputMarginYFrac) * InputRF.Height;

  FontPx := Round(Max(10, InputRF.Height * 0.48));

  // Cache font/fmt/brushes; only create a graphics object if measuring is required.
  EnsureInputTextResources(FontPx);

  ClipRect.X := InputRF.X + MarginX;
  ClipRect.Y := InputRF.Y + MarginY * 0.1;
  ClipRect.Width := Max(0, InputRF.Width - MarginX * 2);
  ClipRect.Height := Max(0, InputRF.Height - MarginY * 0.2);

  NeedMeasure := (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01);

  // Ensure caret is visible by adjusting horizontal scroll
  EnsureCaretInView(FGDIPGraphics, FontPx, FInputFont, FInputFmt);

  if (not FWidthCacheValid) or (Abs(FWidthCacheFontPx - FontPx) > 0.01) then
  begin
    RebuildWidthCache(FGDIPGraphics, FontPx, FInputFont, FInputFmt);
  end;

  CaretScreenX := (ClipRect.X - FScrollX) + CaretIndexToX(FontPx, FCaretPos);
  CaretScreenY := ClipRect.Y + (ClipRect.Height * 0.5);

  BestIdx := -1;
  BestDist := 1.0e100;

  for I := 0 to FKeys.Count - 1 do
  begin
    K := TVKKey(FKeys[I]);
    if (K.RectF.Width <= 0) or (K.RectF.Height <= 0) then Continue;

    Kcx := K.RectF.X + (K.RectF.Width * 0.5);
    Kcy := K.RectF.Y + (K.RectF.Height * 0.5);

    Dx := Kcx - CaretScreenX;
    Dy := Kcy - CaretScreenY;

    Dist := (Dx * Dx) + (Dy * Dy);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      BestIdx := I;
    end;
  end;

  if BestIdx >= 0 then
  begin
    FFocusedKeyIdx := BestIdx;
    FActiveKeyIndex := FFocusedKeyIdx;
  end;

  EnsureFocusedKeyValid;
end;


procedure TVKRenderer.MoveFocusedKeyUpDown(DeltaRow: Integer);
var
  Rows, CurRow, NewRow: Integer;
  CurK: TVKKey;
  RefX: Single;
  NewIdx: Integer;
begin
  EnsureFocusedKeyValid;
  if (FFocusedKeyIdx < 0) or (FFocusedKeyIdx >= FKeys.Count) then Exit;

  Rows := GetRowCount;
  CurRow := GetKeyRowFromIndex(FFocusedKeyIdx);

  if DeltaRow < 0 then
  begin
    // Up: if already on top row, return focus to input
    if CurRow = 0 then
    begin
      SetFocus(vfInput);
      Exit;
    end;
  end
  else if DeltaRow > 0 then
  begin
    // Down: if already on bottom row, return focus to input
    if CurRow = Rows - 1 then
    begin
      SetFocus(vfInput);
      Exit;
    end;
  end;

  NewRow := CurRow + DeltaRow;
  if NewRow < 0 then NewRow := 0;
  if NewRow >= Rows then NewRow := Rows - 1;

  CurK := TVKKey(FKeys[FFocusedKeyIdx]);
  RefX := CurK.RectF.X + (CurK.RectF.Width * 0.5);

  NewIdx := FindClosestKeyInRow(NewRow, RefX);
  if NewIdx >= 0 then
  begin
    FFocusedKeyIdx := NewIdx;
    FActiveKeyIndex := FFocusedKeyIdx;
  end;

  EnsureFocusedKeyValid;
end;


procedure TVKRenderer.MoveFocusedKeyLeftRight(DeltaCol: Integer);
var
  CurRow: Integer;
  StartIdx, Cnt: Integer;
  Rel: Integer;
  NewRel: Integer;
begin
  EnsureFocusedKeyValid;
  if (FFocusedKeyIdx < 0) or (FFocusedKeyIdx >= FKeys.Count) then Exit;

  CurRow := GetKeyRowFromIndex(FFocusedKeyIdx);
  GetRowStartCount(CurRow, StartIdx, Cnt);
  if Cnt <= 0 then Exit;

  Rel := FFocusedKeyIdx - StartIdx;
  NewRel := Rel + DeltaCol;

  if NewRel < 0 then NewRel := 0;
  if NewRel >= Cnt then NewRel := Cnt - 1;

  FFocusedKeyIdx := StartIdx + NewRel;
  FActiveKeyIndex := FFocusedKeyIdx;
  EnsureFocusedKeyValid;
end;


{ Highlight persistence across rebuilds }

function TVKRenderer.MakeKeySignature(K: TVKKey): TVKKeySignature;
begin
  Result.Kind := K.Kind;
  Result.Vk := K.Vk;
  Result.Text := K.Text;
  Result.Output := K.Output;
end;

procedure TVKRenderer.RequestPreserveFocusedKey(K: TVKKey);
begin
  if K = nil then Exit;
  FPendingFocusSig := MakeKeySignature(K);
  FPendingFocusSigValid := True;
end;

function TVKRenderer.FindKeyBySignature(const Sig: TVKKeySignature): Integer;
var
  I: Integer;
  K: TVKKey;
begin
  Result := -1;

  for I := 0 to FKeys.Count - 1 do
  begin
    K := TVKKey(FKeys[I]);
    if K.Kind <> Sig.Kind then Continue;

    // For special keys there is typically only one instance, Kind match is enough.
    if Sig.Kind <> kkChar then
    begin
      Result := I;
      Exit;
    end;

    // For kkChar try stronger matches:
    // 1) VK match (letters page)
    if (Sig.Vk <> 0) and (K.Vk = Sig.Vk) then
    begin
      Result := I;
      Exit;
    end;

    // 2) Text match (symbol toggles like '#+=' or '123' on symbols2)
    if (Sig.Vk = 0) and (Sig.Text <> '') and (K.Text = Sig.Text) then
    begin
      Result := I;
      Exit;
    end;

    // 3) Output match as fallback
    if (Sig.Vk = 0) and (Sig.Output <> '') and (K.Output = Sig.Output) then
    begin
      Result := I;
      Exit;
    end;
  end;
end;


procedure TVKRenderer.ApplyPendingFocusIfAny;
var
  Idx: Integer;
begin
  if not FPendingFocusSigValid then Exit;

  Idx := FindKeyBySignature(FPendingFocusSig);
  if Idx >= 0 then
  begin
    FFocusedKeyIdx := Idx;
    FActiveKeyIndex := FFocusedKeyIdx;
  end;

  FPendingFocusSigValid := False;
end;


procedure TVKRenderer.ActivateKey(K: TVKKey);
begin
  if K = nil then Exit;

  // Preserve highlight on the key being activated, even if it triggers a rebuild.
  if FFocus = vfKeys then
    RequestPreserveFocusedKey(K);

  case K.Kind of
    kkChar:
      begin
        // Special caption keys on symbol pages that act as toggles
        if (K.Text = '#+=') then
        begin
          FPage := vpSymbols2;
          MarkLayoutDirty;
          Exit;
        end
        else if (K.Text = '123') and (FPage = vpSymbols2) then
        begin
          FPage := vpSymbols1;
          MarkLayoutDirty;
          Exit;
        end;

        ReplaceSelection(K.Output);

        // When using letters page, shift acts as momentary shift
        if (FPage = vpLetters) and FShift then
        begin
          FShift := False;
          MarkLayoutDirty;
        end;
      end;

    kkBackspace:
      begin
        if HasSelection then
          DeleteSelection
        else if FCaretPos > 0 then
        begin
          Delete(FText, FCaretPos, 1);
          Dec(FCaretPos);
          ClearSelection;
          FWidthCacheValid := False;
          if Assigned(FOnTextChanged) then FOnTextChanged(Self, FText);
          NotifyInputActivity;
        end;
      end;

    kkShift:
      begin
        FShift := not FShift;
        MarkLayoutDirty;
      end;

    kkSymbols:
      begin
        if FPage = vpLetters then FPage := vpSymbols1
        else FPage := vpLetters;

        MarkLayoutDirty;
      end;

    kkSpace:
      begin
        ReplaceSelection(WideString(' '));
      end;

    kkSubmit:
      begin
        if Assigned(FOnSubmit) then
          FOnSubmit(Self, FText);
      end;

    kkLang:
      begin
        SwitchToNextLayout;
      end;
  end;

  // If activation did NOT rebuild the keyboard, ensure highlight stays on the same key.
  // If it DID rebuild, ApplyPendingFocusIfAny will run inside LayoutKeysIntoRect on next draw.
  if (FFocus = vfKeys) and (not FLayoutDirty) then
    EnsureFocusedKeyValid;
end;

end.

