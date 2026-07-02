unit XelPageControl;

{$mode delphi}

//Author: www.xelitan.com
//License: MIT

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, Forms, Menus, Math, LCLType;

const
  XPC_TAB_HEIGHT = 30;
  XPC_CLOSE_SIZE = 14;

type
  TXelPageControl = class;

  TXelTabSheet = class(TCustomControl)
  private
    FPageControl: TXelPageControl;
    FCaption: TCaption;
    procedure SetCaption(AValue: TCaption);
  protected
    procedure SetParent(NewParent: TWinControl); override;
  public
    constructor Create(AOwner: TComponent); override;
    property PageControl: TXelPageControl read FPageControl;
  published
    property Caption: TCaption read FCaption write SetCaption;
  end;

  // Fired before a tab's close (X) button removes the page. Set AllowClose to
  // False to veto.
  TXelTabCloseEvent = procedure(Sender: TObject; TabIndex: Integer;
    var AllowClose: Boolean) of object;
  TXelTabChangeEvent = procedure(Sender: TObject; TabIndex: Integer) of object;

  // A custom-drawn page control with close (X) buttons whose glyph can be
  // customised via ImageClose, and a per-tab popup menu (TabPopup).
  TXelPageControl = class(TCustomControl)
  private
    FPages: TList;
    FActiveIndex: Integer;
    FTabHeight: Integer;
    FShowCloseButtons: Boolean;
    FImageClose: TBitmap;
    FTabPopup: TPopupMenu;
    FOnTabClose: TXelTabCloseEvent;
    FOnChange: TXelTabChangeEvent;
    FHoverTab: Integer;
    FHoverClose: Boolean;
    FDesignPress: Boolean;
    FDesignBtnDown: Boolean;
    FDesignHover: Boolean;
    FTabRects: array of TRect;
    FCloseRects: array of TRect;
    function GetPage(Index: Integer): TXelTabSheet;
    function GetPageCount: Integer;
    procedure SetActiveIndex(AValue: Integer);
    procedure SetTabHeight(AValue: Integer);
    procedure SetShowCloseButtons(AValue: Boolean);
    procedure SetImageClose(AValue: TBitmap);
    procedure ImageCloseChanged(Sender: TObject);
    procedure UpdateTabRects;
    procedure ShowActivePage;
    procedure CalcTabWidth(out TabW: Integer);
    procedure CloseTab(Index: Integer);
    // Lets the form designer forward mouse clicks on the tab strip to this
    // control, so clicking a tab at design time switches to that page. Close
    // buttons are excluded, so a page cannot be deleted by an X click there.
    procedure CMDesignHitTest(var Message: TCMDesignHitTest); message CM_DESIGNHITTEST;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure Loaded; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    // Called by TXelTabSheet.SetParent so the page list stays in sync for code,
    // the component editor and the LCL streaming system.
    procedure InternalAddPage(APage: TXelTabSheet);
    procedure InternalRemovePage(APage: TXelTabSheet);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function AddPage(const ACaption: string): TXelTabSheet;
    procedure RemovePage(Index: Integer);
    property Pages[Index: Integer]: TXelTabSheet read GetPage;
    property PageCount: Integer read GetPageCount;
    property ActiveIndex: Integer read FActiveIndex write SetActiveIndex;
  published
    property TabHeight: Integer read FTabHeight write SetTabHeight default XPC_TAB_HEIGHT;
    property ShowCloseButtons: Boolean read FShowCloseButtons write SetShowCloseButtons default True;
    property ImageClose: TBitmap read FImageClose write SetImageClose;
    property TabPopup: TPopupMenu read FTabPopup write FTabPopup;
    property OnTabClose: TXelTabCloseEvent read FOnTabClose write FOnTabClose;
    property OnChange: TXelTabChangeEvent read FOnChange write FOnChange;
    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Font;
    property Enabled;
    property Visible;
    property Width default 300;
    property Height default 200;
  end;

procedure Register;

implementation

{$R txelpagecontrol_images.res}

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelPageControl]);
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

{ TXelTabSheet }

constructor TXelTabSheet.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCaption := 'Tab';
  Color    := clBtnFace;
  ControlStyle := ControlStyle + [csAcceptsControls];
end;

procedure TXelTabSheet.SetCaption(AValue: TCaption);
begin
  if FCaption = AValue then Exit;
  FCaption := AValue;
  if Assigned(FPageControl) then FPageControl.Invalidate;
end;

procedure TXelTabSheet.SetParent(NewParent: TWinControl);
var
  OldParent: TWinControl;
begin
  OldParent := Parent;
  inherited SetParent(NewParent);
  if OldParent = NewParent then Exit;
  if OldParent is TXelPageControl then
    TXelPageControl(OldParent).InternalRemovePage(Self);
  if NewParent is TXelPageControl then
    TXelPageControl(NewParent).InternalAddPage(Self);
end;

{ TXelPageControl }

constructor TXelPageControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPages            := TList.Create;
  FActiveIndex      := -1;
  FTabHeight        := XPC_TAB_HEIGHT;
  FShowCloseButtons := True;
  FImageClose       := TBitmap.Create;
  FImageClose.OnChange := ImageCloseChanged;
  FHoverTab         := -1;
  FHoverClose       := False;
  Width  := 300;
  Height := 200;
  ControlStyle := ControlStyle + [csClickEvents, csAcceptsControls];
end;

destructor TXelPageControl.Destroy;
begin
  FPages.Free;
  FPages := nil; // guard: child detach during inherited Destroy must be a no-op
  FImageClose.Free;
  inherited Destroy;
end;

function TXelPageControl.GetPage(Index: Integer): TXelTabSheet;
begin
  Result := TXelTabSheet(FPages[Index]);
end;

function TXelPageControl.GetPageCount: Integer;
begin
  if FPages = nil then Exit(0);
  Result := FPages.Count;
end;

procedure TXelPageControl.SetTabHeight(AValue: Integer);
begin
  FTabHeight := Max(16, AValue);
  ShowActivePage;
  Invalidate;
end;

procedure TXelPageControl.SetShowCloseButtons(AValue: Boolean);
begin
  if FShowCloseButtons = AValue then Exit;
  FShowCloseButtons := AValue;
  UpdateTabRects;
  Invalidate;
end;

procedure TXelPageControl.SetImageClose(AValue: TBitmap);
begin
  FImageClose.Assign(AValue);
end;

procedure TXelPageControl.ImageCloseChanged(Sender: TObject);
begin
  Invalidate;
end;

procedure TXelPageControl.CalcTabWidth(out TabW: Integer);
begin
  // Kept for API compatibility; individual widths are computed in UpdateTabRects.
  TabW := 80;
end;

procedure TXelPageControl.UpdateTabRects;
const
  PAD_TEXT  = 8;   // px po lewej przed tekstem i po tekście
  CLOSE_MAR = 4;   // margines wokół guzika X
var
  i, X, TabW, CloseW: Integer;
begin
  if FPages = nil then Exit;
  SetLength(FTabRects,   FPages.Count);
  SetLength(FCloseRects, FPages.Count);
  Canvas.Font.Assign(Font);
  CloseW := 0;
  if FShowCloseButtons then
    CloseW := XPC_CLOSE_SIZE + CLOSE_MAR * 2;
  X := 0;
  for i := 0 to FPages.Count - 1 do
  begin
    TabW := PAD_TEXT + Canvas.TextWidth(TXelTabSheet(FPages[i]).Caption) + PAD_TEXT + CloseW;
    TabW := Max(40, TabW);
    FTabRects[i] := Rect(X, 0, X + TabW, FTabHeight);
    if FShowCloseButtons then
      FCloseRects[i] := Rect(
        X + TabW - XPC_CLOSE_SIZE - CLOSE_MAR,
        (FTabHeight - XPC_CLOSE_SIZE) div 2,
        X + TabW - CLOSE_MAR,
        (FTabHeight - XPC_CLOSE_SIZE) div 2 + XPC_CLOSE_SIZE)
    else
      FCloseRects[i] := Rect(0, 0, 0, 0);
    Inc(X, TabW);
  end;
end;

procedure TXelPageControl.ShowActivePage;
var
  i: Integer;
  Page: TXelTabSheet;
begin
  if FPages = nil then Exit;
  for i := 0 to FPages.Count - 1 do
  begin
    Page := TXelTabSheet(FPages[i]);
    if i = FActiveIndex then
    begin
      Page.SetBounds(0, FTabHeight, Width, Height - FTabHeight);
      Page.Visible := True;
    end
    else
    begin
      Page.Visible := False;
      // Collapse to zero size so child controls are clipped/hidden even at
      // design time, where the form designer still shows Visible=False controls.
      Page.SetBounds(0, FTabHeight, 0, 0);
    end;
  end;
end;

procedure TXelPageControl.SetActiveIndex(AValue: Integer);
begin
  if FActiveIndex = AValue then Exit;
  FActiveIndex := AValue;
  ShowActivePage;
  Invalidate;
  NotifyDesignerModified(Self);
  if Assigned(FOnChange) and not (csLoading in ComponentState) then
    FOnChange(Self, FActiveIndex);
end;

procedure TXelPageControl.CMDesignHitTest(var Message: TCMDesignHitTest);

  function PressOnTab: Boolean;
  var
    P: TPoint;
    i: Integer;
  begin
    Result := False;
    if FPages = nil then Exit;
    P := Point(Message.Pos.X, Message.Pos.Y);
    UpdateTabRects;
    for i := 0 to FPages.Count - 1 do
      if PtInRect(FTabRects[i], P) and
         not (FShowCloseButtons and PtInRect(FCloseRects[i], P)) then
        Exit(True);
  end;

const
  MK_ANYBTN = MK_LBUTTON or MK_RBUTTON or MK_MBUTTON;
begin
  // The designer re-queries this for every mouse message. The whole gesture
  // must be claimed or released as a unit, decided once at the press: a miss
  // mid-gesture (cursor drifting a pixel off the tab or onto the close button)
  // starts the designer's rubber-band selection. And after a claimed release
  // the designer keeps its internal mouse-down state (TDesigner.MouseUpOnControl
  // exits without clearing MouseDownComponent), which would also rubber-band on
  // plain hover moves — so buttonless moves stay claimed too, until the next
  // press. A right press is never claimed: its release must reach the designer
  // to show the context menu (verbs).
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

procedure TXelPageControl.Paint;
var
  i: Integer;
  TR, CR: TRect;
  CapText: string;
  IsActive, IsHover: Boolean;
  TW: Integer;
begin
  UpdateTabRects;

  // Background below tabs
  Canvas.Brush.Color := clBtnFace;
  Canvas.Pen.Color   := clGray;
  Canvas.Rectangle(0, FTabHeight - 1, Width, Height);

  // Paint tabs
  for i := 0 to FPages.Count - 1 do
  begin
    TR       := FTabRects[i];
    CR       := FCloseRects[i];
    IsActive := (i = FActiveIndex);
    IsHover  := (i = FHoverTab);

    // Tab background
    if IsActive then
      Canvas.Brush.Color := clBtnFace
    else if IsHover then
      Canvas.Brush.Color := $00DDEEFF
    else
      Canvas.Brush.Color := $00CCCCCC;

    Canvas.Pen.Color := clGray;
    Canvas.FillRect(TR);
    // Tab border (no bottom border for active tab so it merges with content)
    Canvas.MoveTo(TR.Left,  TR.Top);
    Canvas.LineTo(TR.Right, TR.Top);
    Canvas.LineTo(TR.Right, TR.Bottom);
    if not IsActive then
      Canvas.LineTo(TR.Left, TR.Bottom);
    Canvas.MoveTo(TR.Left, TR.Bottom);
    Canvas.LineTo(TR.Left, TR.Top);

    // Caption (truncated to the space left of the close button)
    CapText := TXelTabSheet(FPages[i]).Caption;
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Assign(Font);
    if FShowCloseButtons then
      TW := CR.Left - TR.Left - 8
    else
      TW := TR.Right - TR.Left - 10;
    while (Length(CapText) > 1) and (Canvas.TextWidth(CapText) > TW) do
      CapText := Copy(CapText, 1, Length(CapText) - 1);
    Canvas.TextOut(TR.Left + 6, TR.Top + (FTabHeight - Canvas.TextHeight(CapText)) div 2, CapText);
    Canvas.Brush.Style := bsSolid;

    // Close button
    if FShowCloseButtons then
    begin
      if not FImageClose.Empty then
        Canvas.StretchDraw(CR, FImageClose)
      else
      begin
        if IsHover and FHoverClose then
        begin
          Canvas.Brush.Color := clRed;
          Canvas.FillRect(CR);
          Canvas.Pen.Color := clWhite;
        end
        else
          Canvas.Pen.Color := clDkGray;
        Canvas.Pen.Width := 2;
        Canvas.MoveTo(CR.Left + 3,  CR.Top + 3);
        Canvas.LineTo(CR.Right - 3, CR.Bottom - 3);
        Canvas.MoveTo(CR.Right - 3, CR.Top + 3);
        Canvas.LineTo(CR.Left + 3,  CR.Bottom - 3);
        Canvas.Pen.Width := 1;
      end;
    end;
  end;
end;

procedure TXelPageControl.Resize;
begin
  inherited Resize;
  UpdateTabRects;
  ShowActivePage;
end;

procedure TXelPageControl.Loaded;
begin
  inherited Loaded;
  if (FActiveIndex < 0) and (FPages.Count > 0) then
    FActiveIndex := 0;
  UpdateTabRects;
  ShowActivePage;
  Invalidate;
end;

procedure TXelPageControl.CloseTab(Index: Integer);
var
  AllowClose: Boolean;
begin
  if (Index < 0) or (Index >= FPages.Count) then Exit;
  AllowClose := True;
  if Assigned(FOnTabClose) then FOnTabClose(Self, Index, AllowClose);
  if AllowClose then RemovePage(Index);
end;

procedure TXelPageControl.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  UpdateTabRects;

  if Button = mbLeft then
  begin
    for i := 0 to FPages.Count - 1 do
    begin
      if FShowCloseButtons and PtInRect(FCloseRects[i], Point(X, Y)) then
      begin
        CloseTab(i);
        Exit;
      end;
      if PtInRect(FTabRects[i], Point(X, Y)) then
      begin
        SetActiveIndex(i);
        Exit;
      end;
    end;
  end
  else if Button = mbRight then
  begin
    for i := 0 to FPages.Count - 1 do
      if PtInRect(FTabRects[i], Point(X, Y)) then
      begin
        if Assigned(FTabPopup) and not (csDesigning in ComponentState) then
        begin
          FTabPopup.PopupComponent := Pages[i];
          FTabPopup.Popup(ClientToScreen(Point(X, Y)).X,
                          ClientToScreen(Point(X, Y)).Y);
        end;
        Exit;
      end;
  end;
end;

procedure TXelPageControl.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i, OldHover: Integer;
  OldClose: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  UpdateTabRects;
  OldHover := FHoverTab;
  OldClose := FHoverClose;
  FHoverTab   := -1;
  FHoverClose := False;
  for i := 0 to FPages.Count - 1 do
    if PtInRect(FTabRects[i], Point(X, Y)) then
    begin
      FHoverTab   := i;
      FHoverClose := FShowCloseButtons and PtInRect(FCloseRects[i], Point(X, Y));
      Break;
    end;
  if (FHoverTab <> OldHover) or (FHoverClose <> OldClose) then
    Invalidate;
end;

procedure TXelPageControl.MouseLeave;
begin
  inherited MouseLeave;
  FHoverTab   := -1;
  FHoverClose := False;
  Invalidate;
end;

procedure TXelPageControl.InternalAddPage(APage: TXelTabSheet);
begin
  if FPages = nil then Exit;
  if FPages.IndexOf(APage) >= 0 then Exit;
  FPages.Add(APage);
  APage.FPageControl := Self;
  UpdateTabRects;
  if FActiveIndex < 0 then
    SetActiveIndex(FPages.Count - 1)
  else
    ShowActivePage;
  Invalidate;
end;

procedure TXelPageControl.InternalRemovePage(APage: TXelTabSheet);
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
  UpdateTabRects;
  Invalidate;
end;

function TXelPageControl.AddPage(const ACaption: string): TXelTabSheet;
var
  Page: TXelTabSheet;
  PageOwner: TComponent;
begin
  // Own the page by the form (or whoever owns this control) so it is streamed
  // into the .lfm; parent it to the page control so it shows inside it.
  PageOwner := Owner;
  if PageOwner = nil then PageOwner := Self;
  Page := TXelTabSheet.Create(PageOwner);
  Page.Caption := ACaption;
  Page.Parent  := Self; // triggers InternalAddPage via SetParent
  Result := Page;
end;

procedure TXelPageControl.RemovePage(Index: Integer);
begin
  if (Index < 0) or (Index >= FPages.Count) then Exit;
  TXelTabSheet(FPages[Index]).Free; // triggers InternalRemovePage via SetParent(nil)
end;

procedure TXelPageControl.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FTabPopup) then
    FTabPopup := nil;
  if (Operation = opRemove) and (AComponent is TXelTabSheet) then
    InternalRemovePage(TXelTabSheet(AComponent));
end;

initialization
  RegisterClasses([TXelPageControl, TXelTabSheet]);

end.
