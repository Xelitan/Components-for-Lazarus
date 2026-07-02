unit XelRibbon;

{$mode delphi}

//Author: www.xelitan.com
//License: MIT

interface

uses
  Classes, SysUtils, Controls, Graphics, Forms, ExtCtrls, Types, LCLType, Math;

const
  XRB_TAB_HEIGHT   = 28;
  XRB_GROUP_TITLE  = 22;
  XRB_CONTENT_H    = 90;

type
  TXelRibbon = class;
  TXelRibbonPage = class;

  // A visual group inside a ribbon page. User places controls inside it.
  TXelRibbonGroup = class(TCustomControl)
  private
    FCaption: TCaption;
    FGroupWidth: Integer;
    procedure SetCaption(AValue: TCaption);
    procedure SetGroupWidth(AValue: Integer);
  protected
    procedure Paint; override;
    procedure SetParent(NewParent: TWinControl); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Caption: TCaption read FCaption write SetCaption;
    property GroupWidth: Integer read FGroupWidth write SetGroupWidth default 120;
    property Color;
    property Font;
    property Visible;
  end;

  // One tab page of the ribbon. Contains TXelRibbonGroup children laid out left-to-right.
  TXelRibbonPage = class(TCustomControl)
  private
    FCaption: TCaption;
    FRibbon: TXelRibbon;
    procedure SetCaption(AValue: TCaption);
  protected
    procedure SetParent(NewParent: TWinControl); override;
  public
    constructor Create(AOwner: TComponent); override;
    function AddGroup(const ACaption: string; AGroupWidth: Integer = 120): TXelRibbonGroup;
    procedure RebuildGroups;
    property Ribbon: TXelRibbon read FRibbon;
  published
    property Caption: TCaption read FCaption write SetCaption;
  end;

  TXelRibbonChangeEvent = procedure(Sender: TObject; PageIndex: Integer) of object;

  TXelRibbon = class(TCustomControl)
  private
    FPages: TList;
    FActivePageIndex: Integer;
    FOnChange: TXelRibbonChangeEvent;
    FHoverTab: Integer;
    FDesignPress: Boolean;
    FDesignBtnDown: Boolean;
    FDesignHover: Boolean;
    FTabRects: array of TRect;
    FRibbonColor: TColor;
    FTabActiveColor: TColor;
    FTabHoverColor: TColor;
    FTabFontColor: TColor;
    function GetPage(Index: Integer): TXelRibbonPage;
    function GetPageCount: Integer;
    procedure SetActivePageIndex(AValue: Integer);
    procedure UpdateTabRects;
    procedure ShowActivePage;
    // Lets the form designer forward mouse clicks on the tab strip to this
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
    // Called by TXelRibbonPage.SetParent so the page list stays in sync for
    // code, the component editor and the LCL streaming system.
    procedure InternalAddPage(APage: TXelRibbonPage);
    procedure InternalRemovePage(APage: TXelRibbonPage);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function AddPage(const ACaption: string): TXelRibbonPage;
    procedure RemovePage(Index: Integer);
    property Pages[Index: Integer]: TXelRibbonPage read GetPage;
    property PageCount: Integer read GetPageCount;
    property ActivePageIndex: Integer read FActivePageIndex write SetActivePageIndex;
  published
    property RibbonColor: TColor read FRibbonColor write FRibbonColor default $00F0F0E8;
    property TabActiveColor: TColor read FTabActiveColor write FTabActiveColor default clWhite;
    property TabHoverColor: TColor read FTabHoverColor write FTabHoverColor default $00DDEEFF;
    property TabFontColor: TColor read FTabFontColor write FTabFontColor default clBlack;
    property OnChange: TXelRibbonChangeEvent read FOnChange write FOnChange;
    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Font;
    property Visible;
    property Width default 600;
    property Height default 130;
  end;

procedure Register;

implementation

{$R txelribbon_images.res}

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelRibbon]);
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

{ TXelRibbonGroup }

constructor TXelRibbonGroup.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCaption    := 'Group';
  FGroupWidth := 120;
  Color       := $00F0F0E8;
  ControlStyle := ControlStyle + [csAcceptsControls];
end;

procedure TXelRibbonGroup.SetCaption(AValue: TCaption);
begin
  FCaption := AValue;
  Invalidate;
end;

procedure TXelRibbonGroup.SetGroupWidth(AValue: Integer);
begin
  FGroupWidth := Max(40, AValue);
  Width := FGroupWidth;
  if Assigned(Parent) and (Parent is TXelRibbonPage) then
    TXelRibbonPage(Parent).RebuildGroups;
end;

procedure TXelRibbonGroup.SetParent(NewParent: TWinControl);
begin
  inherited SetParent(NewParent);
  if NewParent is TXelRibbonPage then
    TXelRibbonPage(NewParent).RebuildGroups;
end;

procedure TXelRibbonGroup.Paint;
var
  TitleRect, ContentRect: TRect;
  TW, TH: Integer;
begin
  ContentRect := Rect(0, 0, Width, Height - XRB_GROUP_TITLE);
  TitleRect   := Rect(0, Height - XRB_GROUP_TITLE, Width, Height);

  // Content background
  Canvas.Brush.Color := Color;
  Canvas.Pen.Color   := clSilver;
  Canvas.Rectangle(ContentRect);

  // Right separator line
  Canvas.Pen.Color := clSilver;
  Canvas.MoveTo(Width - 1, 0);
  Canvas.LineTo(Width - 1, Height);

  // Title bar at bottom
  Canvas.Brush.Color := $00E8E8E0;
  Canvas.Pen.Color   := clSilver;
  Canvas.FillRect(TitleRect);
  Canvas.MoveTo(0, Height - XRB_GROUP_TITLE);
  Canvas.LineTo(Width, Height - XRB_GROUP_TITLE);

  // Title text centered, in the control's Font
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Assign(Font);
  TW := Canvas.TextWidth(FCaption);
  TH := Canvas.TextHeight(FCaption);
  Canvas.TextOut(
    (Width - TW) div 2,
    TitleRect.Top + (XRB_GROUP_TITLE - TH) div 2,
    FCaption);
  Canvas.Brush.Style := bsSolid;
end;

{ TXelRibbonPage }

constructor TXelRibbonPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCaption := 'Page';
  Color    := $00F0F0E8;
  ControlStyle := ControlStyle + [csAcceptsControls];
end;

procedure TXelRibbonPage.SetCaption(AValue: TCaption);
begin
  if FCaption = AValue then Exit;
  FCaption := AValue;
  if Assigned(FRibbon) then FRibbon.Invalidate;
end;

procedure TXelRibbonPage.SetParent(NewParent: TWinControl);
var
  OldParent: TWinControl;
begin
  OldParent := Parent;
  inherited SetParent(NewParent);
  if OldParent = NewParent then Exit;
  if OldParent is TXelRibbon then
    TXelRibbon(OldParent).InternalRemovePage(Self);
  if NewParent is TXelRibbon then
    TXelRibbon(NewParent).InternalAddPage(Self);
end;

function TXelRibbonPage.AddGroup(const ACaption: string; AGroupWidth: Integer): TXelRibbonGroup;
var
  G: TXelRibbonGroup;
  GroupOwner: TComponent;
begin
  // Own the group by the form so it (and controls dropped on it) is streamed.
  GroupOwner := Owner;
  if GroupOwner = nil then GroupOwner := Self;
  G            := TXelRibbonGroup.Create(GroupOwner);
  G.Caption    := ACaption;
  G.GroupWidth := AGroupWidth;
  G.Height     := Height;
  G.Parent     := Self; // triggers RebuildGroups via SetParent
  Result := G;
end;

procedure TXelRibbonPage.RebuildGroups;
var
  i, XPos: Integer;
  G: TXelRibbonGroup;
begin
  XPos := 0;
  for i := 0 to ControlCount - 1 do
    if Controls[i] is TXelRibbonGroup then
    begin
      G      := TXelRibbonGroup(Controls[i]);
      G.Left := XPos;
      G.Top  := 0;
      G.Height := Height;
      Inc(XPos, G.Width);
    end;
end;

{ TXelRibbon }

constructor TXelRibbon.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPages           := TList.Create;
  FActivePageIndex := -1;
  FHoverTab        := -1;
  FRibbonColor     := $00F0F0E8;
  FTabActiveColor  := clWhite;
  FTabHoverColor   := $00DDEEFF;
  FTabFontColor    := clBlack;
  Width  := 600;
  Height := XRB_TAB_HEIGHT + XRB_CONTENT_H + XRB_GROUP_TITLE + 4;
  ControlStyle := ControlStyle + [csClickEvents, csAcceptsControls];
end;

destructor TXelRibbon.Destroy;
begin
  FPages.Free;
  FPages := nil; // guard: child detach during inherited Destroy must be a no-op
  inherited Destroy;
end;

function TXelRibbon.GetPage(Index: Integer): TXelRibbonPage;
begin
  Result := TXelRibbonPage(FPages[Index]);
end;

function TXelRibbon.GetPageCount: Integer;
begin
  if FPages = nil then Exit(0);
  Result := FPages.Count;
end;

procedure TXelRibbon.UpdateTabRects;
var
  i, X: Integer;
  TabW: Integer;
begin
  SetLength(FTabRects, FPages.Count);
  X := 4;
  for i := 0 to FPages.Count - 1 do
  begin
    Canvas.Font.Assign(Font);
    TabW := Canvas.TextWidth(TXelRibbonPage(FPages[i]).Caption) + 20;
    FTabRects[i] := Rect(X, 0, X + TabW, XRB_TAB_HEIGHT);
    Inc(X, TabW + 2);
  end;
end;

procedure TXelRibbon.ShowActivePage;
var
  i: Integer;
  ContentH: Integer;
  Page: TXelRibbonPage;
begin
  if FPages = nil then Exit;
  ContentH := Height - XRB_TAB_HEIGHT - 1;
  for i := 0 to FPages.Count - 1 do
  begin
    Page := TXelRibbonPage(FPages[i]);
    if i = FActivePageIndex then
    begin
      // Zaczynamy od XRB_TAB_HEIGHT+1: rząd XRB_TAB_HEIGHT należy wyłącznie
      // do TXelRibbon i nie jest przykrywany przez dziecko – dzięki temu
      // pozioma linia (rysowana w Paint) jest widoczna.
      Page.SetBounds(0, XRB_TAB_HEIGHT + 1, Width, Max(0, ContentH));
      Page.Visible := True;
      Page.RebuildGroups;
    end
    else
    begin
      Page.Visible := False;
      // Collapse to zero size so groups/controls are clipped/hidden even at
      // design time, where the form designer still shows Visible=False controls.
      Page.SetBounds(0, XRB_TAB_HEIGHT, 0, 0);
    end;
  end;
end;

procedure TXelRibbon.SetActivePageIndex(AValue: Integer);
begin
  if FActivePageIndex = AValue then Exit;
  FActivePageIndex := AValue;
  ShowActivePage;
  Invalidate;
  NotifyDesignerModified(Self);
  if Assigned(FOnChange) and not (csLoading in ComponentState) then
    FOnChange(Self, FActivePageIndex);
end;

procedure TXelRibbon.CMDesignHitTest(var Message: TCMDesignHitTest);

  function PressOnTab: Boolean;
  var
    P: TPoint;
    i: Integer;
  begin
    Result := False;
    if FPages = nil then Exit;
    P := Point(Message.Pos.X, Message.Pos.Y);
    if P.Y >= XRB_TAB_HEIGHT then Exit;
    UpdateTabRects;
    for i := 0 to FPages.Count - 1 do
      if PtInRect(FTabRects[i], P) then
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

procedure TXelRibbon.Paint;
var
  i: Integer;
  TR: TRect;
  CapText: string;
  TW, TH: Integer;
  IsActive, IsHover: Boolean;
begin
  UpdateTabRects;

  // Full background
  Canvas.Brush.Color := FRibbonColor;
  Canvas.FillRect(ClientRect);

  // Pozioma linia na dole paska zakładek – z przerwą w miejscu aktywnej zakładki
  Canvas.Pen.Color := clGray;
  if (FActivePageIndex >= 0) and (FActivePageIndex < Length(FTabRects)) then
  begin
    TR := FTabRects[FActivePageIndex];
    if TR.Left > 0 then
    begin
      Canvas.MoveTo(0, XRB_TAB_HEIGHT);
      Canvas.LineTo(TR.Left, XRB_TAB_HEIGHT);
    end;
    if TR.Right < Width then
    begin
      Canvas.MoveTo(TR.Right, XRB_TAB_HEIGHT);
      Canvas.LineTo(Width, XRB_TAB_HEIGHT);
    end;
  end
  else
  begin
    Canvas.MoveTo(0, XRB_TAB_HEIGHT);
    Canvas.LineTo(Width, XRB_TAB_HEIGHT);
  end;

  // Draw tabs
  for i := 0 to FPages.Count - 1 do
  begin
    TR       := FTabRects[i];
    IsActive := (i = FActivePageIndex);
    IsHover  := (i = FHoverTab);
    CapText  := TXelRibbonPage(FPages[i]).Caption;

    if IsActive then
      Canvas.Brush.Color := FTabActiveColor
    else if IsHover then
      Canvas.Brush.Color := FTabHoverColor
    else
      Canvas.Brush.Color := FRibbonColor;

    Canvas.Pen.Color := clGray;
    if IsActive then
    begin
      // Active tab: top + sides border, no bottom (merges with content)
      Canvas.FillRect(TR);
      Canvas.MoveTo(TR.Left,  TR.Top);
      Canvas.LineTo(TR.Right, TR.Top);
      Canvas.LineTo(TR.Right, TR.Bottom + 1);
      Canvas.MoveTo(TR.Left,  TR.Bottom + 1);
      Canvas.LineTo(TR.Left,  TR.Top);
    end
    else
    begin
      Canvas.FillRect(TR);
    end;

    Canvas.Brush.Style := bsClear;
    Canvas.Font.Assign(Font);
    Canvas.Font.Color := FTabFontColor;
    if IsActive then Canvas.Font.Style := [fsBold];
    TW := Canvas.TextWidth(CapText);
    TH := Canvas.TextHeight(CapText);
    Canvas.TextOut(TR.Left + (TR.Right - TR.Left - TW) div 2,
                   TR.Top  + (XRB_TAB_HEIGHT - TH) div 2,
                   CapText);
    Canvas.Brush.Style := bsSolid;
    Canvas.Font.Style  := [];
    Canvas.Font.Color  := clDefault;
  end;
end;

procedure TXelRibbon.Resize;
begin
  inherited Resize;
  ShowActivePage;
end;

procedure TXelRibbon.Loaded;
var
  i: Integer;
begin
  inherited Loaded;
  if (FActivePageIndex < 0) and (FPages.Count > 0) then
    FActivePageIndex := 0;
  for i := 0 to FPages.Count - 1 do
    TXelRibbonPage(FPages[i]).RebuildGroups;
  ShowActivePage;
  Invalidate;
end;

procedure TXelRibbon.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and (Y < XRB_TAB_HEIGHT) then
  begin
    UpdateTabRects;
    for i := 0 to FPages.Count - 1 do
      if PtInRect(FTabRects[i], Point(X, Y)) then
      begin
        SetActivePageIndex(i);
        Exit;
      end;
  end;
end;

procedure TXelRibbon.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i, OldHover: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  OldHover  := FHoverTab;
  FHoverTab := -1;
  if Y < XRB_TAB_HEIGHT then
  begin
    UpdateTabRects;
    for i := 0 to FPages.Count - 1 do
      if PtInRect(FTabRects[i], Point(X, Y)) then
      begin
        FHoverTab := i;
        Break;
      end;
  end;
  if FHoverTab <> OldHover then Invalidate;
end;

procedure TXelRibbon.MouseLeave;
begin
  inherited MouseLeave;
  FHoverTab := -1;
  Invalidate;
end;

procedure TXelRibbon.InternalAddPage(APage: TXelRibbonPage);
begin
  if FPages = nil then Exit;
  if FPages.IndexOf(APage) >= 0 then Exit;
  FPages.Add(APage);
  APage.FRibbon := Self;
  if FActivePageIndex < 0 then
    SetActivePageIndex(FPages.Count - 1)
  else
    ShowActivePage;
  Invalidate;
end;

procedure TXelRibbon.InternalRemovePage(APage: TXelRibbonPage);
var
  Idx: Integer;
begin
  if FPages = nil then Exit;
  Idx := FPages.IndexOf(APage);
  if Idx < 0 then Exit;
  FPages.Delete(Idx);
  if FActivePageIndex >= FPages.Count then
    FActivePageIndex := FPages.Count - 1;
  ShowActivePage;
  Invalidate;
end;

function TXelRibbon.AddPage(const ACaption: string): TXelRibbonPage;
var
  Page: TXelRibbonPage;
  PageOwner: TComponent;
begin
  PageOwner := Owner;
  if PageOwner = nil then PageOwner := Self;
  Page := TXelRibbonPage.Create(PageOwner);
  Page.Caption := ACaption;
  Page.Parent  := Self; // triggers InternalAddPage via SetParent
  Result := Page;
end;

procedure TXelRibbon.RemovePage(Index: Integer);
begin
  if (Index < 0) or (Index >= FPages.Count) then Exit;
  TXelRibbonPage(FPages[Index]).Free; // triggers InternalRemovePage via SetParent(nil)
end;

procedure TXelRibbon.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent is TXelRibbonPage) then
    InternalRemovePage(TXelRibbonPage(AComponent));
end;

initialization
  RegisterClasses([TXelRibbon, TXelRibbonPage, TXelRibbonGroup]);

end.
