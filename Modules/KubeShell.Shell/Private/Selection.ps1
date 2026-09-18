# Internal implementation for KubeShell.Shell. Loaded into the parent module scope.

function Select-KubeResource {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$InputObject)
    begin { $items = [Collections.Generic.List[object]]::new() }
    process { [void]$items.Add($InputObject) }
    end {
        if ($items.Count -eq 0) { return }
        if ($items.Count -eq 1) { return $items[0] }

        $fzf = Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue
        if ($fzf) {
            $indexed = for ($i=0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                $itemNamespace = (Get-KubePropertyValue $item @('Namespace')) ?? ''
                $itemKind = (Get-KubePropertyValue $item @('kind')) ?? $item.PSObject.TypeNames[0]
                $itemName = (Get-KubePropertyValue $item @('Name')) ?? $item.ToString()
                "{0}`t{1}`t{2}`t{3}" -f $i, $itemNamespace, $itemKind, $itemName
            }
            $selected = $indexed | & $fzf.Source '--with-nth=2..'
            if (-not $selected) { return }
            $index = [int](($selected -split "`t",2)[0])
            return $items[$index]
        }

        for ($i=0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            $itemNamespace = (Get-KubePropertyValue $item @('Namespace')) ?? '-'
            $itemName = (Get-KubePropertyValue $item @('Name')) ?? $item.ToString()
            Write-Host ('[{0}] {1}/{2}' -f $i, $itemNamespace, $itemName)
        }
        $selection = Read-Host 'Select index'
        if ($selection -notmatch '^\d+$' -or [int]$selection -ge $items.Count) { throw 'Invalid selection.' }
        return $items[[int]$selection]
    }
}
