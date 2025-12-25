{$DEFINE BENCHMARK}

unit MainUnit;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, VK_MultiLingualVirtualKeyboard, TNTForms;

type
  TVKForm = class(TTNTForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormShow(Sender: TObject);
  private
    { Private declarations }
    {procedure WMChar(var Msg: TWMChar); message WM_CHAR;
    procedure WMUniChar(var Msg: TMessage); message $0109; // WM_UNICHAR}
    procedure AppMessage(var Msg: TMsg; var Handled: Boolean);
  public
    { Public declarations }
    bgColor : TRGBAColor;
    MyBackgroundBitmap : TBitmap;
    procedure SubmitSearch(Sender: TObject; const Query: WideString);
    procedure UpdateLayeredWindow;
  end;

const
  inputX    : Integer = 50;
  inputY    : Integer = 100;
  inputW    : Integer = 1180;
  inputH    : Integer = 60;

  keyboardX : Integer = 50;
  keyboardY : Integer = 200;
  keyboardW : Integer = 1180;
  keyboardH : Integer = 400;

var
  VK    : TVKRenderer;
  VKForm : TVKForm;


implementation


{$R *.dfm}




procedure TVKForm.SubmitSearch(Sender: TObject; const Query: WideString);
begin
  ShowMessage('Submitted "'+Query+'"');
end;


procedure TVKForm.AppMessage(var Msg: TMsg; var Handled: Boolean);
var
  UnicodeMsg: TMsg;
  WC        : WideChar;
begin
  // We only care about keyboard character messages to support unicode
  if (Msg.message = WM_CHAR) and (Msg.hwnd = VKForm.Handle) then
  begin
    If Msg.wParam <> 27 then
    Begin
      WC := WideChar(Msg.wParam);
      VK.WideKeyPress(WC);

      VK.DrawInputFieldArea;
      VK.DrawKeyboardArea;
      UpdateLayeredWindow;
    End
    Else Close;
    Handled := True;
  end;
end;


procedure TVKForm.FormCreate(Sender: TObject);
begin
  bgColor.R :=   0;
  bgColor.G :=   0;
  bgColor.B :=   0;
  bgColor.A := 215;

  SetWindowLong(Handle, GWL_EXSTYLE, GetWindowLong(Handle, GWL_EXSTYLE) or WS_EX_LAYERED);

  Application.OnMessage := AppMessage;

  MyBackgroundBitmap := TBitmap.Create;
  MyBackgroundBitmap.PixelFormat := pf32bit;
  //MyBackgroundBitmap.Canvas.Brush.Color := $FFFFFF;
  MyBackgroundBitmap.Width  := 1280;
  MyBackgroundBitmap.Height := 720;
  //sFillRect32(MyBackgroundBitmap,0,0,1280,720,Cardinal(bgColor));

  VK := TVKRenderer.Create;

  // Your 32bit background bitmap (pf32bit) used as render target
  VK.SetTargetBitmap(MyBackgroundBitmap,bgColor);

  // Set rectangles (in bitmap coordinates)
  VK.SetInputRect(Rect(inputX, inputY, inputX+inputW-1,inputY+inputH-1));
  VK.SetKeyLayoutRect(Rect(keyboardX,keyboardY,keyboardX+keyboardW-1,keyboardY+keyboardH-1));

  // Optional: tweak spacing
  //VK.KeyMarginXFrac := 0.012;
  //VK.KeyMarginYFrac := 0.014;

  // Optional: events
  VK.OnSubmit := SubmitSearch;
end;


procedure TVKForm.FormDestroy(Sender: TObject);
begin
  MyBackgroundBitmap.Free;
  VK.Free;
end;


procedure TVKForm.FormMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  VK.MouseDown(X, Y, Button);

  // Redraw background area(s):
  VK.DrawInputFieldArea;
  VK.DrawKeyboardArea;
  UpdateLayeredWindow;

  If Shift = [ssLeft,ssCtrl] then
  Begin
    ReleaseCapture;
    PostMessage(VKForm.Handle,WM_SYSCOMMAND,$F012,0);
  End;
end;


procedure TVKForm.FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  If Shift = [ssLeft] then
  Begin
    VK.MouseMove(X, Y, Shift);
    VK.DrawInputFieldArea;
    UpdateLayeredWindow;
  End;
end;


procedure TVKForm.FormMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  VK.MouseUp(X, Y, Button);
  VK.DrawInputFieldArea;
  UpdateLayeredWindow;
end;


procedure TVKForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  I, iTS : Cardinal;
begin
  // Benchmark
  {$IFDEF BENCHMARK}
  If Key = VK_HOME then
  Begin
    iTS := GetTickCount;
    For I := 0 to 499 do
    Begin
      VK.DrawInputFieldArea;
      VK.DrawKeyboardArea;
    End;
    ShowMessage(FloatToStr((GetTickCount-iTS)/500)+'ms');
  End;
  {$ENDIF}

  VK.KeyDown(Key, Shift);
  VK.DrawInputFieldArea;
  VK.DrawKeyboardArea;

  UpdateLayeredWindow;
end;


procedure TVKForm.UpdateLayeredWindow;
var
  Blend: TBLENDFUNCTION;
  P,P2: TPoint;
  S: TSize;
begin
  // 1. Draw Static Background to Buffer FIRST (Requirement 4 & 8)
  // In a real app, optimize: only redraw background if dirty.
  // Here we draw the background image onto the buffer.
  // Note: Simple Draw() might lose alpha channel in D7 TBitmap.
  // For production, use GDI+ to draw FBackgroundImg onto FBackBuffer.
  // Assuming FVirtualKB.Draw* handles the composite over this.

  Blend.BlendOp := AC_SRC_OVER;
  Blend.BlendFlags := 0;
  Blend.SourceConstantAlpha := 255;
  Blend.AlphaFormat := AC_SRC_ALPHA;

  P    := Point(Left, Top);
  P2   := Point(0,0);
  S.cx := MyBackgroundBitmap.Width;
  S.cy := MyBackgroundBitmap.Height;

  Windows.UpdateLayeredWindow(Handle, 0, @P, @S, MyBackgroundBitmap.Canvas.Handle, @P2, 0, @Blend, ULW_ALPHA);
end;


procedure TVKForm.FormShow(Sender: TObject);
begin
  // Clear Background
  sFillRect32(MyBackgroundBitmap,0,0,1280,720,Cardinal(bgColor));

  VK.DrawInputFieldArea;
  VK.DrawKeyboardArea;
  UpdateLayeredWindow;
end;


end.
