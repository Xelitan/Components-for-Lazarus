unit XelDsgn;

{ Design-time support for the Xelitan container components. Adds right-click
  context-menu verbs (like TPageControl) to create/delete/navigate pages,
  sections and ribbon groups, and hides the sub-page classes from the palette
  while keeping them streamable. Requires the IDEIntf package. }

{$mode delphi}

interface

procedure Register;

implementation

uses
  Classes, ComponentEditors, PropEdits,
  XelSidePages, XelAccordion, XelRibbon, XelPageControl;

type
  TXelPageControlEditor = class(TComponentEditor)
  public
    function GetVerbCount: Integer; override;
    function GetVerb(Index: Integer): string; override;
    procedure ExecuteVerb(Index: Integer); override;
  end;

  TXelSidePagesEditor = class(TComponentEditor)
  public
    function GetVerbCount: Integer; override;
    function GetVerb(Index: Integer): string; override;
    procedure ExecuteVerb(Index: Integer); override;
  end;

  TXelAccordionEditor = class(TComponentEditor)
  public
    function GetVerbCount: Integer; override;
    function GetVerb(Index: Integer): string; override;
    procedure ExecuteVerb(Index: Integer); override;
  end;

  TXelRibbonEditor = class(TComponentEditor)
  public
    function GetVerbCount: Integer; override;
    function GetVerb(Index: Integer): string; override;
    procedure ExecuteVerb(Index: Integer); override;
  end;

// Registers a freshly created sub-component with the designer: gives it a
// unique name, selects it in the Object Inspector and flags the form modified.
procedure FinishAdd(AnEditor: TComponentEditor; AChild: TComponent);
begin
  if AnEditor.GetDesigner = nil then Exit;
  if AChild.Name = '' then
    AChild.Name := AnEditor.GetDesigner.CreateUniqueComponentName(AChild.ClassName);
  AnEditor.GetDesigner.PropertyEditorHook.PersistentAdded(AChild, True);
  AnEditor.Modified;
end;

{ TXelPageControlEditor }

function TXelPageControlEditor.GetVerbCount: Integer;
begin
  Result := 4;
end;

function TXelPageControlEditor.GetVerb(Index: Integer): string;
begin
  case Index of
    0: Result := 'New page';
    1: Result := 'Delete active page';
    2: Result := 'Next page';
    3: Result := 'Previous page';
  else
    Result := '';
  end;
end;

procedure TXelPageControlEditor.ExecuteVerb(Index: Integer);
var
  PC: TXelPageControl;
  Page: TXelTabSheet;
begin
  PC := GetComponent as TXelPageControl;
  case Index of
    0:
      begin
        Page := PC.AddPage('Tab');
        PC.ActiveIndex := PC.PageCount - 1;
        FinishAdd(Self, Page);
      end;
    1:
      if (PC.ActiveIndex >= 0) and (PC.ActiveIndex < PC.PageCount) then
      begin
        PC.RemovePage(PC.ActiveIndex);
        Modified;
      end;
    2:
      if PC.ActiveIndex < PC.PageCount - 1 then
      begin
        PC.ActiveIndex := PC.ActiveIndex + 1;
        Modified;
      end;
    3:
      if PC.ActiveIndex > 0 then
      begin
        PC.ActiveIndex := PC.ActiveIndex - 1;
        Modified;
      end;
  end;
end;

{ TXelSidePagesEditor }

function TXelSidePagesEditor.GetVerbCount: Integer;
begin
  Result := 4;
end;

function TXelSidePagesEditor.GetVerb(Index: Integer): string;
begin
  case Index of
    0: Result := 'New page';
    1: Result := 'Delete active page';
    2: Result := 'Next page';
    3: Result := 'Previous page';
  else
    Result := '';
  end;
end;

procedure TXelSidePagesEditor.ExecuteVerb(Index: Integer);
var
  SP: TXelSidePages;
  Page: TXelSidePage;
begin
  SP := GetComponent as TXelSidePages;
  case Index of
    0:
      begin
        Page := SP.AddPage('Page');
        SP.ActiveIndex := SP.PageCount - 1;
        FinishAdd(Self, Page);
      end;
    1:
      if (SP.ActiveIndex >= 0) and (SP.ActiveIndex < SP.PageCount) then
      begin
        SP.RemovePage(SP.ActiveIndex);
        Modified;
      end;
    2:
      if SP.ActiveIndex < SP.PageCount - 1 then
      begin
        SP.ActiveIndex := SP.ActiveIndex + 1;
        Modified;
      end;
    3:
      if SP.ActiveIndex > 0 then
      begin
        SP.ActiveIndex := SP.ActiveIndex - 1;
        Modified;
      end;
  end;
end;

{ TXelAccordionEditor }

function TXelAccordionEditor.GetVerbCount: Integer;
begin
  Result := 4;
end;

function TXelAccordionEditor.GetVerb(Index: Integer): string;
begin
  case Index of
    0: Result := 'New section';
    1: Result := 'Delete last section';
    2: Result := 'Expand next section';
    3: Result := 'Expand previous section';
  else
    Result := '';
  end;
end;

procedure TXelAccordionEditor.ExecuteVerb(Index: Integer);
var
  AC: TXelAccordion;
  Section: TXelAccordionSection;
  Idx: Integer;
begin
  AC := GetComponent as TXelAccordion;
  case Index of
    0:
      begin
        Section := AC.AddSection('Section');
        FinishAdd(Self, Section);
      end;
    1:
      begin
        Idx := AC.ActiveSectionIndex;
        if Idx < 0 then Idx := AC.SectionCount - 1;
        if (Idx >= 0) and (Idx < AC.SectionCount) then
        begin
          AC.RemoveSection(Idx);
          Modified;
        end;
      end;
    2:
      begin
        // -1 (nothing expanded) -> expand the first section
        Idx := AC.ActiveSectionIndex + 1;
        if Idx < AC.SectionCount then
        begin
          AC.ExpandSection(Idx);
          Modified;
        end;
      end;
    3:
      begin
        Idx := AC.ActiveSectionIndex;
        if Idx < 0 then
          Idx := AC.SectionCount - 1 // nothing expanded -> expand the last one
        else
          Dec(Idx);
        if Idx >= 0 then
        begin
          AC.ExpandSection(Idx);
          Modified;
        end;
      end;
  end;
end;

{ TXelRibbonEditor }

function TXelRibbonEditor.GetVerbCount: Integer;
begin
  Result := 5;
end;

function TXelRibbonEditor.GetVerb(Index: Integer): string;
begin
  case Index of
    0: Result := 'New page';
    1: Result := 'New group on active page';
    2: Result := 'Delete active page';
    3: Result := 'Next page';
    4: Result := 'Previous page';
  else
    Result := '';
  end;
end;

procedure TXelRibbonEditor.ExecuteVerb(Index: Integer);
var
  RB: TXelRibbon;
  Page: TXelRibbonPage;
  Group: TXelRibbonGroup;
begin
  RB := GetComponent as TXelRibbon;
  case Index of
    0:
      begin
        Page := RB.AddPage('Page');
        RB.ActivePageIndex := RB.PageCount - 1;
        FinishAdd(Self, Page);
      end;
    1:
      if (RB.ActivePageIndex >= 0) and (RB.ActivePageIndex < RB.PageCount) then
      begin
        Group := RB.Pages[RB.ActivePageIndex].AddGroup('Group');
        FinishAdd(Self, Group);
      end;
    2:
      if (RB.ActivePageIndex >= 0) and (RB.ActivePageIndex < RB.PageCount) then
      begin
        RB.RemovePage(RB.ActivePageIndex);
        Modified;
      end;
    3:
      if RB.ActivePageIndex < RB.PageCount - 1 then
      begin
        RB.ActivePageIndex := RB.ActivePageIndex + 1;
        Modified;
      end;
    4:
      if RB.ActivePageIndex > 0 then
      begin
        RB.ActivePageIndex := RB.ActivePageIndex - 1;
        Modified;
      end;
  end;
end;

procedure Register;
begin
  // Keep the sub-page classes off the palette but registered for streaming and
  // for the IDE to recognise them when reading a form.
  RegisterNoIcon([TXelTabSheet, TXelSidePage, TXelAccordionSection,
    TXelRibbonPage, TXelRibbonGroup]);

  RegisterComponentEditor(TXelPageControl, TXelPageControlEditor);
  RegisterComponentEditor(TXelSidePages, TXelSidePagesEditor);
  RegisterComponentEditor(TXelAccordion, TXelAccordionEditor);
  RegisterComponentEditor(TXelRibbon, TXelRibbonEditor);
end;

end.
