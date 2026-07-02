unit XelAccordion;

{$mode delphi}

//Author: www.xelitan.com
//License: MIT

interface

uses
  Classes, SysUtils, Controls, Graphics, Forms, LCLType, Math;

const
  XAC_HEADER_HEIGHT = 30;

type
  TXelAccordion = class;

  TXelAccordionSection = class(TCustomControl)
  private
    FAccordion: TXelAccordion;
    FCaption: TCaption;
    FExpanded: Boolean;
    FExpandedHeight: Integer;
    FHeaderColor: TColor;
    FHeaderFontColor: TColor;
    FHoverHeader: Boolean;
    FDesignPress: Boolean;
    FDesignBtnDown: Boolean;
    FDesignHover: Boolean;
    procedure SetExpanded(AValue: Boolean);
    procedure SetCaption(AValue: TCaption);
    function IsInHeader(Y: Integer): Boolean;
    // Lets the form designer forward mouse clicks on the header to this
    // control, so sections can be expanded/collapsed at design time too.
    procedure CMDesignHitTest(var Message: TCMDesignHitTest); message CM_DESIGNHITTEST;
  protected
    procedure Paint; override;
    procedure SetParent(NewParent: TWinControl); override;
    procedure SetBounds(ALeft, ATop, AWidth, AHeight: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Accordion: TXelAccordion read FAccordion;
  published
    property Caption: TCaption read FCaption write SetCaption;
    property ExpandedHeight: Integer read FExpandedHeight write FExpandedHeight default 120;
    property Expanded: Boolean read FExpanded write SetExpanded default False;
    property HeaderColor: TColor read FHeaderColor write FHeaderColor default $00604020;
    property HeaderFontColor: TColor read FHeaderFontColor write FHeaderFontColor default clWhite;
    property Color;
    property Font;
  end;

  TXelAccordionChangeEvent = procedure(Sender: TObject; SectionIndex: Integer) of object;

  TXelAccordion = class(TCustomControl)
  private
    FSections: TList;
    FActiveSectionIndex: Integer;
    FOnChange: TXelAccordionChangeEvent;
    function GetSection(Index: Integer): TXelAccordionSection;
    function GetSectionCount: Integer;
    procedure SetActiveSectionIndex(AValue: Integer);
  protected
    procedure Loaded; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    // Called by TXelAccordionSection.SetParent so the section list stays in sync
    // for code, the component editor and the LCL streaming system.
    procedure InternalAddSection(ASection: TXelAccordionSection);
    procedure InternalRemoveSection(ASection: TXelAccordionSection);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function AddSection(const ACaption: string): TXelAccordionSection;
    procedure RemoveSection(Index: Integer);
    procedure SectionToggled(ASection: TXelAccordionSection);
    procedure ExpandSection(Index: Integer);
    procedure RebuildLayout;
    property Sections[Index: Integer]: TXelAccordionSection read GetSection;
    property SectionCount: Integer read GetSectionCount;
    property ActiveSectionIndex: Integer read FActiveSectionIndex write SetActiveSectionIndex;
  published
    property OnChange: TXelAccordionChangeEvent read FOnChange write FOnChange;
    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Visible;
    property Width default 200;
    property Height default 300;
  end;

procedure Register;

implementation

{$R txelaccordion_images.res}

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelAccordion]);
end;

// Marks the parent form modified in the IDE, so state changed by design-time
// mouse clicks (expanded section, its new height) gets saved to the .lfm.
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

// Returns AColor darkened by Amount (0..255) on each RGB channel
function DarkenColor(AColor: TColor; Amount: Integer): TColor;
var
  RGBVal: LongInt;
  R, G, B: Integer;
begin
  RGBVal := ColorToRGB(AColor);
  R := Max(0, (RGBVal and $FF) - Amount);
  G := Max(0, ((RGBVal shr 8) and $FF) - Amount);
  B := Max(0, ((RGBVal shr 16) and $FF) - Amount);
  Result := TColor((B shl 16) or (G shl 8) or R);
end;

{ TXelAccordionSection }

constructor TXelAccordionSection.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCaption         := 'Section';
  FExpanded        := False;
  FExpandedHeight  := 120;
  FHeaderColor     := $00604020;
  FHeaderFontColor := clWhite;
  FHoverHeader     := False;
  Height := XAC_HEADER_HEIGHT;
  ControlStyle := ControlStyle + [csClickEvents, csAcceptsControls];
end;

procedure TXelAccordionSection.SetCaption(AValue: TCaption);
begin
  FCaption := AValue;
  Invalidate;
end;

procedure TXelAccordionSection.SetParent(NewParent: TWinControl);
var
  OldParent: TWinControl;
begin
  OldParent := Parent;
  inherited SetParent(NewParent);
  if OldParent = NewParent then Exit;
  if OldParent is TXelAccordion then
    TXelAccordion(OldParent).InternalRemoveSection(Self);
  if NewParent is TXelAccordion then
    TXelAccordion(NewParent).InternalAddSection(Self);
end;

procedure TXelAccordionSection.SetBounds(ALeft, ATop, AWidth, AHeight: Integer);
begin
  // The accordion stacks its sections vertically at full width. Force the
  // horizontal geometry so a section cannot be dragged sideways or width-resized
  // in the form designer, which would otherwise wreck the layout.
  if Assigned(FAccordion) then
  begin
    ALeft  := 0;
    AWidth := FAccordion.Width;
  end;
  inherited SetBounds(ALeft, ATop, AWidth, AHeight);
end;

procedure TXelAccordionSection.SetExpanded(AValue: Boolean);
begin
  if FExpanded = AValue then Exit;
  FExpanded := AValue;
  if FExpanded then
    Height := XAC_HEADER_HEIGHT + FExpandedHeight
  else
    Height := XAC_HEADER_HEIGHT;
  if Assigned(FAccordion) and not (csLoading in ComponentState) then
    FAccordion.RebuildLayout;
  Invalidate;
end;

procedure TXelAccordionSection.CMDesignHitTest(var Message: TCMDesignHitTest);
const
  MK_ANYBTN = MK_LBUTTON or MK_RBUTTON or MK_MBUTTON;
begin
  // The designer re-queries this for every mouse message. The whole gesture
  // must be claimed or released as a unit, decided once at the press: a miss
  // mid-gesture starts the designer's rubber-band selection (the section may
  // move under the cursor when toggling reflows the layout). And after a
  // claimed release the designer keeps its internal mouse-down state
  // (TDesigner.MouseUpOnControl exits without clearing MouseDownComponent),
  // which would also rubber-band on plain hover moves — so buttonless moves
  // stay claimed too, until the next press. A right press is never claimed:
  // its release must reach the designer to show the context menu.
  if (Message.Keys and MK_ANYBTN) <> 0 then
  begin
    if not FDesignBtnDown then
    begin
      FDesignBtnDown := True;
      FDesignHover   := False;
      FDesignPress   := ((Message.Keys and MK_ANYBTN) = MK_LBUTTON) and
                        IsInHeader(Message.Pos.Y);
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

function TXelAccordionSection.IsInHeader(Y: Integer): Boolean;
begin
  Result := Y <= XAC_HEADER_HEIGHT;
end;

procedure TXelAccordionSection.Paint;
var
  HeaderRect, ContentRect: TRect;
  TH, CY: Integer;
  HdrColor: TColor;
begin
  HeaderRect  := Rect(0, 0, Width, XAC_HEADER_HEIGHT);
  ContentRect := Rect(0, XAC_HEADER_HEIGHT, Width, Height);

  // Header background (slightly lighter on hover)
  if FHoverHeader then
    HdrColor := $00806040
  else
    HdrColor := FHeaderColor;

  Canvas.Brush.Color := HdrColor;
  Canvas.Pen.Color   := HdrColor;
  Canvas.FillRect(HeaderRect);

  // Border at bottom of header
  Canvas.Pen.Color := DarkenColor(FHeaderColor, 40);
  Canvas.MoveTo(0, XAC_HEADER_HEIGHT - 1);
  Canvas.LineTo(Width, XAC_HEADER_HEIGHT - 1);

  // Arrow: drawn as a triangle instead of a Unicode glyph, whose font
  // fallback rendering can look clipped/overdrawn on some systems.
  CY := XAC_HEADER_HEIGHT div 2;
  Canvas.Brush.Color := FHeaderFontColor;
  Canvas.Pen.Color   := FHeaderFontColor;
  if FExpanded then
    Canvas.Polygon([Point(7, CY - 2), Point(17, CY - 2), Point(12, CY + 4)])
  else
    Canvas.Polygon([Point(9, CY - 5), Point(9, CY + 5), Point(15, CY)]);

  // Caption
  Canvas.Font.Color  := FHeaderFontColor;
  Canvas.Font.Style  := [fsBold];
  Canvas.Brush.Style := bsClear;
  TH := Canvas.TextHeight(FCaption);
  Canvas.TextOut(24, (XAC_HEADER_HEIGHT - TH) div 2, FCaption);
  Canvas.Brush.Style := bsSolid;
  Canvas.Font.Style  := [];

  // Content area
  if FExpanded then
  begin
    Canvas.Brush.Color := Color;
    Canvas.Pen.Color   := clSilver;
    Canvas.Rectangle(ContentRect);
  end;
end;

procedure TXelAccordionSection.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and IsInHeader(Y) and Assigned(FAccordion) then
    FAccordion.SectionToggled(Self);
end;

procedure TXelAccordionSection.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  WasHover: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  WasHover     := FHoverHeader;
  FHoverHeader := IsInHeader(Y);
  if FHoverHeader <> WasHover then Invalidate;
end;

procedure TXelAccordionSection.MouseLeave;
begin
  inherited MouseLeave;
  FHoverHeader := False;
  Invalidate;
end;

procedure TXelAccordionSection.Resize;
begin
  inherited Resize;
  // Keep expandedHeight in sync when user resizes at design time while expanded
  if FExpanded and (Height > XAC_HEADER_HEIGHT) then
    FExpandedHeight := Height - XAC_HEADER_HEIGHT;
end;

{ TXelAccordion }

constructor TXelAccordion.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSections           := TList.Create;
  FActiveSectionIndex := -1;
  Width  := 200;
  Height := 300;
  ControlStyle := ControlStyle + [csAcceptsControls];
end;

destructor TXelAccordion.Destroy;
begin
  FSections.Free;
  FSections := nil; // guard: child detach during inherited Destroy must be a no-op
  inherited Destroy;
end;

function TXelAccordion.GetSection(Index: Integer): TXelAccordionSection;
begin
  Result := TXelAccordionSection(FSections[Index]);
end;

function TXelAccordion.GetSectionCount: Integer;
begin
  if FSections = nil then Exit(0);
  Result := FSections.Count;
end;

procedure TXelAccordion.SetActiveSectionIndex(AValue: Integer);
begin
  if (AValue < 0) or (AValue >= FSections.Count) then Exit;
  FActiveSectionIndex := AValue;
  SectionToggled(Sections[AValue]);
end;

procedure TXelAccordion.Loaded;
begin
  inherited Loaded;
  RebuildLayout;
  Invalidate;
end;

procedure TXelAccordion.InternalAddSection(ASection: TXelAccordionSection);
begin
  if FSections = nil then Exit;
  if FSections.IndexOf(ASection) >= 0 then Exit;
  FSections.Add(ASection);
  ASection.FAccordion := Self;
  ASection.Width := Width;
  RebuildLayout;
end;

procedure TXelAccordion.InternalRemoveSection(ASection: TXelAccordionSection);
var
  Idx: Integer;
begin
  if FSections = nil then Exit;
  Idx := FSections.IndexOf(ASection);
  if Idx < 0 then Exit;
  FSections.Delete(Idx);
  if FActiveSectionIndex >= FSections.Count then
    FActiveSectionIndex := FSections.Count - 1;
  RebuildLayout;
end;

function TXelAccordion.AddSection(const ACaption: string): TXelAccordionSection;
var
  S: TXelAccordionSection;
  SectOwner: TComponent;
begin
  // Own the section by the form so it (and any controls dropped on it) is
  // streamed into the .lfm; parent it to the accordion for display/layout.
  SectOwner := Owner;
  if SectOwner = nil then SectOwner := Self;
  S          := TXelAccordionSection.Create(SectOwner);
  S.Caption  := ACaption;
  S.Parent   := Self; // triggers InternalAddSection via SetParent
  Result := S;
end;

procedure TXelAccordion.RemoveSection(Index: Integer);
begin
  if (Index < 0) or (Index >= FSections.Count) then Exit;
  TXelAccordionSection(FSections[Index]).Free; // triggers InternalRemoveSection
end;

procedure TXelAccordion.SectionToggled(ASection: TXelAccordionSection);
var
  i, Idx: Integer;
  S: TXelAccordionSection;
begin
  Idx := FSections.IndexOf(ASection);
  if Idx < 0 then Exit;

  // Collapse all, expand only the clicked one (toggle if already open)
  for i := 0 to FSections.Count - 1 do
  begin
    S := Sections[i];
    if i = Idx then
      S.Expanded := not S.Expanded
    else
      S.Expanded := False;
  end;

  // Find which one is now active
  FActiveSectionIndex := -1;
  for i := 0 to FSections.Count - 1 do
    if Sections[i].Expanded then
    begin
      FActiveSectionIndex := i;
      Break;
    end;

  RebuildLayout;
  NotifyDesignerModified(Self);
  if Assigned(FOnChange) and not (csLoading in ComponentState) then
    FOnChange(Self, FActiveSectionIndex);
end;

procedure TXelAccordion.ExpandSection(Index: Integer);
var
  i: Integer;
begin
  if (FSections = nil) or (Index < 0) or (Index >= FSections.Count) then Exit;
  for i := 0 to FSections.Count - 1 do
    Sections[i].Expanded := (i = Index);
  FActiveSectionIndex := Index;
  RebuildLayout;
  if Assigned(FOnChange) and not (csLoading in ComponentState) then
    FOnChange(Self, FActiveSectionIndex);
end;

procedure TXelAccordion.RebuildLayout;
var
  i, YPos: Integer;
  S: TXelAccordionSection;
begin
  if FSections = nil then Exit;
  YPos := 0;
  for i := 0 to FSections.Count - 1 do
  begin
    S       := Sections[i];
    S.Left  := 0;
    S.Width := Width;
    S.Top   := YPos;
    Inc(YPos, S.Height);
  end;
end;

procedure TXelAccordion.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent is TXelAccordionSection) then
    InternalRemoveSection(TXelAccordionSection(AComponent));
end;

initialization
  RegisterClasses([TXelAccordion, TXelAccordionSection]);

end.
