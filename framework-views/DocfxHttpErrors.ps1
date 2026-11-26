function New-DocfxHttpErrors([string] $Stage, $Build, [string] $ApiPath) {
    $source = "$Stage/framework-template/http-errors"
    New-Item -ItemType Directory -Path $source | Out-Null
    $template = Get-Content -LiteralPath "$PSScriptRoot/http-error.md.tmpl" -Raw
    $errors = @(
        ,@(400, 'Bad Request', 'Check the documentation address and any selected framework.')
        ,@(401, 'Unauthorized', 'Sign in with an account that has access to this documentation.')
        ,@(403, 'Forbidden', 'Your current access does not allow you to open this page.')
        ,@(404, 'Not Found', 'The documentation page may have moved or the address may be incorrect.')
        ,@(405, 'Method Not Allowed', 'Open the documentation page directly in your browser.')
        ,@(408, 'Request Timeout', 'The request took too long to arrive. Try opening the page again.')
        ,@(410, 'Gone', 'This documentation page has been removed. Search for its replacement.')
        ,@(412, 'Precondition Failed', 'Open the page again to request its current version.')
        ,@(413, 'Content Too Large', 'The request is too large. Try opening the page directly.')
        ,@(414, 'URI Too Long', 'Shorten the address or search for the page from the documentation home.')
        ,@(415, 'Unsupported Media Type', 'Open the documentation page directly in your browser.')
        ,@(416, 'Range Not Satisfiable', 'Open the page again to request the complete document.')
        ,@(429, 'Too Many Requests', 'Wait a moment before making another request.')
        ,@(500, 'Internal Server Error', 'The page could not be served. Try again in a moment.')
        ,@(501, 'Not Implemented', 'This request is unsupported. Open the page directly in your browser.')
        ,@(502, 'Bad Gateway', 'The documentation is temporarily unavailable. Try again in a moment.')
        ,@(503, 'Service Unavailable', 'The documentation is temporarily unavailable. Try again in a moment.')
        ,@(504, 'Gateway Timeout', 'The request took too long to complete. Try again in a moment.')
        ,@(505, 'HTTP Version Not Supported', 'Open the documentation in a current browser.')
    )
    foreach ($errorPage in $errors) {
        $code, $heading, $message = $errorPage
        $page = $template.Replace('__STATUS__', $code).Replace('__HEADING__', $heading).
            Replace('__MESSAGE__', $message).Replace('__API_PATH__', "/$ApiPath/")
        Set-Content -LiteralPath "$source/$code.md" -Value $page
        $code
    }
    $Build.content = @($Build['content'] ?? @()) + @{ src = 'framework-template/http-errors'; dest = '_docfx-errors'; files = @('*.md') }
}

function Complete-DocfxHttpErrors([string] $Site, [int[]] $Statuses) {
    # Compatible templates already load this shared asset on normal documentation pages.
    Add-Content -LiteralPath "$Site/public/framework-view.js" -Value ("`n" + (Get-Content -LiteralPath "$PSScriptRoot/http-error.js" -Raw))
    $head = @'
$0
    <base href="/_docfx-errors/">
    <meta name="robots" content="noindex">
    <meta name="referrer" content="no-referrer">
    <script defer src="/public/framework-view.js"></script>
'@
    foreach ($status in $Statuses) {
        $path = "$Site/_docfx-errors/$status.html"
        $html = Get-Content -LiteralPath $path -Raw
        # Modern DocFX resolves these against location.href, independently of the HTML base URL.
        $html = $html -creplace '(<meta name="docfx:(?:navrel|tocrel|rel)" content=")\.\./', '$1/'
        $html -creplace '<html\s*>', '<html lang="en">' -creplace '<head(?:\s[^>]*)?>', $head |
            Set-Content -LiteralPath $path -NoNewline
    }
}
