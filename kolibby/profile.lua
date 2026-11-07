-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Request defaults for API and publication downloads.
local U=require("kolibby/util")
local M={
    spec="V32",client="d:22.2.1",shell="n-a:9.5.0",
    webview_user_agent="Mozilla/5.0 (Linux; Android 13; sdk_gphone64_arm64 Build/TE1A.240213.009; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/155.0.8059.43 Mobile Safari/537.36 (Dewey; V32; Android; 9.5.0; RELEASE)",
    native_user_agent="Dalvik/2.1.0 (Linux; U; Android 13; sdk_gphone64_arm64 Build/TE1A.240213.009)",
}
local names={['user-agent']='User-Agent',['accept-encoding']='Accept-Encoding',['accept-language']='Accept-Language',
    ['content-type']='Content-Type',['content-length']='Content-Length',accept='Accept',authorization='Authorization',
    connection='Connection',host='Host',cookie='Cookie',origin='Origin',['x-requested-with']='X-Requested-With',
    ['sec-fetch-dest']='Sec-Fetch-Dest',['sec-fetch-mode']='Sec-Fetch-Mode',['sec-fetch-site']='Sec-Fetch-Site',
    ['access-control-allow-origin']='Access-Control-Allow-Origin'}
function M.headers(kind,provided,encodings)
    local h={}
    if kind=="api" then
        h={['User-Agent']=M.webview_user_agent,Accept='application/json',['Accept-Language']='en-US',
            ['Accept-Encoding']=encodings.web,Connection='keep-alive',Origin='https://libbyapp.com',
            ['X-Requested-With']='com.overdrive.mobile.android.libby',['Sec-Fetch-Dest']='empty',
            ['Sec-Fetch-Mode']='cors',['Sec-Fetch-Site']='same-site',['sec-ch-ua-platform']='"Android"',
            ['sec-ch-ua']='"Android WebView";v="155", "Chromium";v="155", "Not(A:Brand";v="24"',
            ['sec-ch-ua-mobile']='?1'}
    else
        h={['User-Agent']=M.native_user_agent,['Accept-Encoding']=encodings.native,Connection='Keep-Alive'}
        if kind~="roster" then h['Access-Control-Allow-Origin']='*' end
    end
    for name,value in pairs(provided or {}) do
        local lower=name:lower();local canonical=names[lower] or lower
        h[canonical]=value
    end
    return h
end
function M.normalize_headers(headers)
    local out={};for k,v in pairs(headers or {}) do out[k:lower()]=v end;return out
end
function M.context(loan,card)
    local loan_key=loan.key:gsub(":","-")
    local title={titleId=loan.id,slug=loan.id}
    if type(loan.cover)=="table" then title.cover=U.copy(loan.cover) end
    local library={key=card.advantage_key,name=card.library}
    if card.logo_url then library.logoURL=card.logo_url end
    if type(card.colors)=="table" then library.colors=U.copy(card.colors) end
    return {['dewey-url']='https://libbyapp.com',spec=M.spec,codex={title=title,loan={psnKey=loan_key,slug=loan_key},library=library}}
end
return M
