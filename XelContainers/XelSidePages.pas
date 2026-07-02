unit XelSidePages;

{$mode delphi}

//Author: www.xelitan.com
//License: MIT

interface

uses
  Classes, SysUtils, Controls, Graphics, Forms, Math, Types, LCLType;

type
  TXelSideTabPos = (stpLeft, stpRight);

  TXelSidePages = class;

  TXelSidePage = class(TCustomControl)
  private
    FCaption: TCaption;
    FSidePages: TXelSidePages;
    procedure SetCaption(AValue: TCaption);
  protected
    procedure SetParent(NewParent: TWinControl); override;
  public
    constructor Create(AOwner: TComponent); override;
    property SidePages: TXelSidePages read FSidePages;
  published
    property Caption: TCaption read FCaption write SetCaption;
  end;

  TXelSideChangeEvent = procedure(Sender: TObject; PageIndex: Integer) of object;

  TXelSidePages = class(TCustomControl)
  private
    FPages: TList;
    FActiveIndex: Integer;
    FTabPosition: TXelSideTabPos;
    FTabWidth: Integer;
    FActiveTabColor: TColor;
    FInactiveTabColor: TColor;
    FTabFontColor: TColor;
    FActiveTabFontColor: TColor;
    FOnChange: TXelSideChangeEvent;
    FHoverTab: Integer;
    FDesignPress: Boolean;
    FDesignBtnDown: Boolean;
    FDesignHover: Boolean;
    function GetPage(Index: Integer): TXelSidePage;
    function GetPageCount: Integer;
    procedure SetActiveIndex(AValue: Integer);
    procedure SetTabPosition(AValue: TXelSideTabPos);
    procedure SetTabWidth(AValue: Integer);
    function ContentRect: TRect;
    procedure ShowActivePage;
    function TabRect(Index: Integer): TRect;
    // Lets the form designer forward mouse clicks on the tab column to this
    // control, so clicking a tab at design time switches to that page.
    procedure CMDesignHitTest(var Message: TCMDesignHitTest); message CM_DESIGNHITTEST;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure Loaded; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    // Called by TXelSidePage.SetParent so the container keeps its page list in
    // sync whether pages are added by code, by the component editor, or by the
    // LCL streaming system when a form is loaded.
    procedure InternalAddPage(APage: TXelSidePage);
    procedure InternalRemovePage(APage: TXelSidePage);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function AddPage(const ACaption: string): TXelSidePage;
    procedure RemovePage(Index: Integer);
    property Pages[Index: Integer]: TXelSidePage read GetPage;
    property PageCount: Integer read GetPageCount;
    property ActiveIndex: Integer read FActiveIndex write SetActiveIndex;
  published
    property TabPosition: TXelSideTabPos read FTabPosition write SetTabPosition default stpLeft;
    property TabWidth: Integer read FTabWidth write SetTabWidth default 120;
    property ActiveTabColor: TColor read FActiveTabColor write FActiveTabColor default clHighlight;
    property InactiveTabColor: TColor read FInactiveTabColor write FInactiveTabColor default $00CCCCCC;
    property TabFontColor: TColor read FTabFontColor write FTabFontColor default clBlack;
    property ActiveTabFontColor: TColor read FActiveTabFontColor write FActiveTabFontColor default clWhite;
    property OnChange: TXelSideChangeEvent read FOnChange write FOnChange;
    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Font;
    property Visible;
    property Width default 340;
    property Height default 250;
  end;

procedure Register;

implementation

{$R txelsidepages_images.res}

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelSidePages]);
end;

// Marks the parent form modified in the IDE, so state changed by design-time
// mouse clicks (page bounds/visibility) gets saved to the .lfm.
procedure NotifyDesignerModified(AControl: TControl);
var
  F: TCustomForm;
begin
  if not (csDesigning in AControl.ComponentState) then Exit;
  if csLoading in AControl.ComponentState then Exit;
  F := GetParentForm(AControl);
  if (F <> nil) and (F.Designer <> nil) then
    F.Designer.Modified;
end;

{ TXelSidePage }

constructor TXelSidePage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCaption := 'Page';
  Color    := clBtnFace;
  ControlStyle := ControlStyle + [csAcceptsControls];
end;

procedure TXelSidePage.SetCaption(AValue: TCaption);
begin
  if FCaption = AValue then Exit;
  FCaption := AValue;
  if Assigned(FSidePages) then FSidePages.Invalidate;
end;

procedure TXelSidePage.SetParent(NewParent: TWinControl);
var
  OldParent: TWinControl;
begin
  OldParent := Parent;
  inherited SetParent(NewParent);
  if OldParent = NewParent then Exit;
  if OldParent is TXelSidePages then
    TXelSidePages(OldParent).InternalRemovePage(Self);
  if NewParent is TXelSidePages then
    TXelSidePages(NewParent).InternalAddPage(Self);
end;

{ TXelSidePages }

constructor TXelSidePages.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPages            := TList.Create;
  FActiveIndex      := -1;
  FTabPosition      := stpLeft;
  FTabWidth         := 120;
  FActiveTabColor   := clHighlight;
  FInactiveTabColor := $00CCCCCC;
  FTabFontColor     := clBlack;
  FActiveTabFontColor := clWhite;
  FHoverTab         := -1;
  Width  := 340;
  Height := 250;
  ControlStyle := ControlStyle + [csClickEvents, csAcceptsControls];
end;

destructor TXelSidePages.Destroy;
begin
  FPages.Free;
  FPages := nil; // guard: child detach during inherited Destroy must be a no-op
  inherited Destroy;
end;

function TXelSidePages.GetPage(Index: Integer): TXelSidePage;
begin
  Result := TXelSidePage(FPages[Index]);
end;

function TXelSidePages.GetPageCount: Integer;
begin
  if FPages = nil then Exit(0);
  Result := FPages.Count;
end;

procedure TXelSidePages.SetTabPosition(AValue: TXelSideTabPos);
begin
  FTabPosition := AValue;
  ShowActivePage;
  Invalidate;
end;

procedure TXelSidePages.SetTabWidth(AValue: Integer);
begin
  FTabWidth := Max(40, AValue);
  ShowActivePage;
  Invalidate;
end;

function TXelSidePages.ContentRect: TRect;
begin
  if FTabPosition = stpLeft then
    Result := Rect(FTabWidth + 1, 0, Width, Height)
  else
    Result := Rect(0, 0, Width - FTabWidth - 1, Height);
end;

function TXelSidePages.TabRect(Index: Integer): TRect;
const
  TAB_H = 32;
begin
  if FTabPosition = stpLeft then
    Result := Rect(0, Index * TAB_H, FTabWidth, (Index + 1) * TAB_H)
  else
    Result := Rect(Width - FTabWidth, Index * TAB_H, Width, (Index + 1) * TAB_H);
end;

procedure TXelSidePages.ShowActivePage;
var
  i: Integer;
  CR: TRect;
  Page: TXelSidePage;
begin
  if FPages = nil then Exit;
  CR := ContentRect;
  for i := 0 to FPages.Count - 1 do
  begin
    Page := TXelSidePage(FPages[i]);
    if i = FActiveIndex then
    begin
      Page.SetBounds(CR.Left, CR.Top, CR.Right - CR.Left, CR.Bottom - CR.Top);
      Page.Visible := True;
    end
    else
    begin
      Page.Visible := False;
      // Collapse to zero size so child controls are clipped/hidden even at
      // design time, where the form designer still shows Visible=False controls.
      Page.SetBounds(CR.Left, CR.Top, 0, 0);
    end;
  end;
end;

procedure TXelSidePages.SetActiveIndex(AValue: Integer);
begin
  if FActiveIndex = AValue then Exit;
  FActiveIndex := AValue;
  ShowActivePage;
  Invalidate;
  NotifyDesignerModified(Self);
  if Assigned(FOnChange) and not (csLoading in ComponentState) then
    FOnChange(Self, FActiveIndex);
end;

procedure TXelSidePages.CMDesignHitTest(var Message: TCMDesignHitTest);

  function PressOnTab: Boolean;
  var
    P: TPoint;
    i: Integer;
  begin
    Result := False;
    if FPages = nil then Exit;
    P := Point(Message.Pos.X, Message.Pos.Y);
    for i := 0 to FPages.Count - 1 do
      if PtInRect(TabRect(i), P) then
        Exit(True);
  end;

const
  MK_ANYBTN = MK_LBUTTON or MK_RBUTTON or MK_MBUTTON;
begin
  // The designer re-queries this for every mouse message. The whole gesture
  // must be claimed or released as a unit, decided once at the press: a miss
  // mid-gesture (cursor drifting a pixel off the tab) starts the designer's
  // rubber-band selection. And after a claimed release the designer keeps its
  // internal mouse-down state (TDesigner.MouseUpOnControl exits without
  // clearing MouseDownComponent), which would also rubber-band on plain hover
  // moves — so buttonless moves stay claimed too, until the next press. A
  // right press is never claimed: its release must reach the designer to show
  // the context menu (verbs).
  if (Message.Keys and MK_ANYBTN) <> 0 then
  begin
    if not FDesignBtnDown then
    begin
      FDesignBtnDown := True;
      FDesignHover   := False;
      FDesignPress   := ((Message.Keys and MK_ANYBTN) = MK_LBUTTON) and PressOnTab;
    end;
    Message.Result := Ord(FDesignPress);
  end
  else if FDesignBtnDown then
  begin
    // Release ending the gesture
    Message.Result := Ord(FDesignPress);
    FDesignHover   := FDesignPress;
    FDesignBtnDown := False;
    FDesignPress   := False;
  end
  else
    Message.Result := Ord(FDesignHover);
end;

procedure TXelSidePages.Paint;
var
  i: Integer;
  TR, CR: TRect;
  CapText: string;
  TH, LineX: Integer;
  LastTabBottom: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);

  if FTabPosition = stpLeft then LineX := FTabWidth
  else LineX := Width - FTabWidth;

  CR := ContentRect;   // Rect(LineX+1, 0, ...) / Rect(0, 0, LineX-1, ...)


  Canvas.Brush.Color := clBtnFace;
  Canvas.Pen.Color   := clBtnFace;
  Canvas.FillRect(CR);


  Canvas.Pen.Color := clGray;
  if FTabPosition = stpLeft then
  begin
    Canvas.MoveTo(LineX, 0);        Canvas.LineTo(Width, 0);
    Canvas.MoveTo(Width - 1, 0);    Canvas.LineTo(Width - 1, Height);
    Canvas.MoveTo(LineX, Height - 1); Canvas.LineTo(Width, Height - 1);
  end
  else
  begin
    Canvas.MoveTo(LineX, 0);        Canvas.LineTo(0, 0);
    Canvas.MoveTo(0, 0);            Canvas.LineTo(0, Height);
    Canvas.MoveTo(LineX, Height - 1); Canvas.LineTo(0, Height - 1);
  end;

  Canvas.Pen.Color := clGray;
  if FPages.Count > 0 then
  begin
    LastTabBottom := TabRect(FPages.Count - 1).Bottom;
    if LastTabBottom < Height then
    begin
      Canvas.MoveTo(LineX, LastTabBottom);
      Canvas.LineTo(LineX, Height);
    end;
  end
  else
  begin
    Canvas.MoveTo(LineX, 0);
    Canvas.LineTo(LineX, Height);
  end;

  // Draw tabs
  for i := 0 to FPages.Count - 1 do
  begin
    TR := TabRect(i);

    if i = FActiveIndex then
      Canvas.Brush.Color := FActiveTabColor
    else if i = FHoverTab then
      Canvas.Brush.Color := $00AAAAAA
    else
      Canvas.Brush.Color := FInactiveTabColor;

    Canvas.Pen.Color := clGray;
    Canvas.Rectangle(TR);

    // Tab label
    CapText := TXelSidePage(FPages[i]).Caption;
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Assign(Font);
    if i = FActiveIndex then
      Canvas.Font.Color := FActiveTabFontColor
    else
      Canvas.Font.Color := FTabFontColor;

    TH := Canvas.TextHeight(CapText);
    Canvas.TextOut(TR.Left + 8, TR.Top + (TR.Bottom - TR.Top - TH) div 2, CapText);
    Canvas.Brush.Style := bsSolid;
    Canvas.Font.Color  := clDefault;
  end;
end;

procedure TXelSidePages.Resize;
begin
  inherited Resize;
  ShowActivePage;
end;

procedure TXelSidePages.Loaded;
begin
  inherited Loaded;
  if (FActiveIndex < 0) and (FPages.Count > 0) then
    FActiveIndex := 0;
  ShowActivePage;
  Invalidate;
end;

procedure TXelSidePages.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
    for i := 0 to FPages.Count - 1 do
      if PtInRect(TabRect(i), Point(X, Y)) then
      begin
        SetActiveIndex(i);
        Exit;
      end;
end;

procedure TXelSidePages.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i, OldHover: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  OldHover  := FHoverTab;
  FHoverTab := -1;
  for i := 0 to FPages.Count - 1 do
    if PtInRect(TabRect(i), Point(X, Y)) then
    begin
      FHoverTab := i;
      Break;
    end;
  if FHoverTab <> OldHover then Invalidate;
end;

procedure TXelSidePages.MouseLeave;
begin
  inherited MouseLeave;
  FHoverTab := -1;
  Invalidate;
end;

procedure TXelSidePages.InternalAddPage(APage: TXelSidePage);
begin
  if FPages = nil then Exit;
  if FPages.IndexOf(APage) >= 0 then Exit;
  FPages.Add(APage);
  APage.FSidePages := Self;
  if FActiveIndex < 0 then
    SetActiveIndex(FPages.Count - 1)
  else
    ShowActivePage;
  Invalidate;
end;

procedure TXelSidePages.InternalRemovePage(APage: TXelSidePage);
var
  Idx: Integer;
begin
  if FPages = nil then Exit;
  Idx := FPages.IndexOf(APage);
  if Idx < 0 then Exit;
  FPages.Delete(Idx);
  if FActiveIndex >= FPages.Count then
    FActiveIndex := FPages.Count - 1;
  ShowActivePage;
  Invalidate;
end;

function TXelSidePages.AddPage(const ACaption: string): TXelSidePage;
var
  Page: TXelSidePage;
  PageOwner: TComponent;
begin
  // Own the page by the form (or whoever owns this control) so it is streamed
  // into the .lfm; parent it to the container so it shows inside it.
  PageOwner := Owner;
  if PageOwner = nil then PageOwner := Self;
  Page := TXelSidePage.Create(PageOwner);
  Page.Caption := ACaption;
  Page.Parent  := Self; // triggers InternalAddPage via SetParent
  Result := Page;
end;

procedure TXelSidePages.RemovePage(Index: Integer);
begin
  if (Index < 0) or (Index >= FPages.Count) then Exit;
  TXelSidePage(FPages[Index]).Free; // triggers InternalRemovePage via SetParent(nil)
end;

procedure TXelSidePages.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent is TXelSidePage) then
    InternalRemovePage(TXelSidePage(AComponent));
end;

initialization
  RegisterClasses([TXelSidePages, TXelSidePage]);

end.
