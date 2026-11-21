#requires -Version 7.0
function Invoke-ThesisBeforeBuild {
    param([string]$Root, [ValidateSet('Ask', 'Skip')][string]$Mode = 'Ask')
    if ($Mode -eq 'Skip') { Write-Host 'Git commit skipped.'; return $true }
    $changes = @(Get-ThesisChanges $Root)
    if (-not $changes.Count) { Write-Host 'Working tree is clean; nothing to commit.'; return $true }
    if ($changes.Status -match 'U|AA|DD') { throw 'Resolve Git merge conflicts before building.' }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Interactive build requires pwsh -STA, or use -CommitMode Skip.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    $form.Text = '论文编译：是否先提交 Git？'
    $form.ClientSize = [Drawing.Size]::new(760, 500)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
    $label = [Windows.Forms.Label]::new()
    $label.Text = '勾选要提交的文件；提交保存这些文件当前的全部修改（含未暂存内容）。'
    $label.SetBounds(16, 15, 730, 30)
    $list = [Windows.Forms.CheckedListBox]::new()
    $list.SetBounds(16, 50, 728, 310)
    $list.CheckOnClick = $true
    $list.HorizontalScrollbar = $true
    foreach ($change in $changes) { $null = $list.Items.Add($change.Label, $true) }
    $messageLabel = [Windows.Forms.Label]::new()
    $messageLabel.Text = '提交说明（仅本地 commit）：'
    $messageLabel.SetBounds(16, 370, 720, 25)
    $message = [Windows.Forms.TextBox]::new()
    $message.SetBounds(16, 400, 728, 28)
    $message.Text = 'docs: 论文编译前快照 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $commit = [Windows.Forms.Button]::new()
    $commit.Text = '提交后编译'
    $commit.SetBounds(284, 450, 145, 32)
    $skip = [Windows.Forms.Button]::new()
    $skip.Text = '直接编译'
    $skip.SetBounds(442, 450, 145, 32)
    $skip.DialogResult = [Windows.Forms.DialogResult]::No
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.SetBounds(600, 450, 145, 32)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $commit.Add_Click({
        if ($list.CheckedIndices.Count -eq 0 -or [string]::IsNullOrWhiteSpace($message.Text)) {
            $null = [Windows.Forms.MessageBox]::Show($form, '请勾选文件并填写提交说明。', '无法提交')
            return
        }
        $form.DialogResult = [Windows.Forms.DialogResult]::Yes
        $form.Close()
    })
    $form.Controls.AddRange(@($label, $list, $messageLabel, $message, $commit, $skip, $cancel))
    $form.AcceptButton = $skip
    $form.CancelButton = $cancel
    $form.ActiveControl = $skip
    try {
        $answer = $form.ShowDialog()
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
            $paths = @($list.CheckedIndices | ForEach-Object { $changes[$_].Paths } | Select-Object -Unique)
            Save-ThesisCommit -Root $Root -Paths $paths -Message $message.Text
            return $true
        }
        return $answer -eq [Windows.Forms.DialogResult]::No
    } finally { $form.Dispose() }
}
