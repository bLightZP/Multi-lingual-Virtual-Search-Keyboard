program VirtualKeyboard;

uses
  Forms,
  MainUnit in 'MainUnit.pas' {VKForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TVKForm, VKForm);
  Application.Run;
end.
