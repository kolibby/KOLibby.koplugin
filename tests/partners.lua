-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local M=require('kolibby/model');local J=require('kolibby/json');local P=require('kolibby/presentation')
local U=require('kolibby/util');local B=require('kolibby/borrowing');local Batch=require('kolibby/batch')
local function home(id,puid,name)
 return {cardId=id,puid=puid,cardName=name or 'Family',library={name='Home Library',websiteId='home-system'},isVisitingCard=false}
end
local function partner(id,parent)
 return {cardId=id,isVisitingCard=true,homeLibraryPUID=parent,homeLibraryWebsiteId='home-system',library={name='Partner Library',websiteId='partner-system'}}
end
local function loan(card,id)
 return {cardId=card,id=id or 'book',checkoutId='checkout-'..card,title='Synthetic Book',type={id='ebook',name='eBook'},formats={{id='ebook-overdrive'}},expireDate='2030-01-01T00:00:00Z'}
end
local function response(cards,loans,holds) return {result='synchronized',cards=cards,loans=loans or {},holds=holds or {}} end
local function merge(cards,loans,holds) return M.merge(M.empty(),response(cards,loans,holds),1) end

test('Visiting cards carry partner attribution from an explicit home patron link',function()
 local state=merge({partner('visitor','patron-A'),home('base','patron-A')},{loan('visitor')})
 eq(state.cards.visitor.name,'Partner card');eq(state.cards.visitor.home_card_id,'base');eq(state.cards.visitor.is_partner,true)
 contains(M.card_label(state,'visitor'),'Partner Library');contains(M.card_label(state,'visitor'),'Partner via Home Library · Family')
 local summary=P.summary(state.loans['visitor:book'],state)
 eq(summary.library,'Partner Library · Partner card');eq(summary.attribution,'Partner via Home Library · Family')
 eq(M.card_attribution(state,'base'),nil)
end)
test('Two cards at the same home library are distinguished by exact patron identity',function()
 local a,b=home('first','patron-A','First'),home('second','patron-B','Second')
 a.username='same-private-login';b.username=a.username
 local state=merge({a,b,partner('visitor','patron-B')})
 eq(state.cards.visitor.home_card_id,'second');contains(M.card_attribution(state,'visitor'),'Second')
end)
test('A partner relationship never becomes a replacement-card alias',function()
 local state=merge({home('base','patron-A'),partner('visitor','patron-A')},{loan('base'),loan('visitor')})
 eq(M.card_for(state,'visitor').id,'visitor');eq(state.card_aliases.visitor,nil)
 eq(#M.list(state,'loans','base'),1);eq(#M.list(state,'loans','visitor'),1)
 local plan=Batch.plan(state,{}, {now=1,card_id='visitor',exists=function() return false end})
 eq(#plan.queue,1);eq(plan.queue[1].card_id,'visitor')
end)
test('Website or username equality alone does not identify a home card',function()
 local p=partner('visitor','unknown');p.username='private-login'
 local h=home('base','patron-A');h.username=p.username
 local state=merge({h,p})
 eq(state.cards.visitor.home_card_id,nil);eq(M.card_attribution(state,'visitor'),nil)
 contains(M.card_label(state,'visitor'),'Partner card')
end)
test('Ambiguous and inconsistent home metadata does not produce attribution',function()
 local state=merge({home('one','duplicate'),home('two','duplicate'),partner('visitor','duplicate')})
 eq(state.cards.visitor.home_card_id,nil)
 local p=partner('visitor','patron-A');p.homeLibraryWebsiteId='different-system'
 state=merge({home('base','patron-A'),p});eq(state.cards.visitor.home_card_id,nil)
end)
test('Only the explicit visiting-card flag enables partner handling',function()
 local p=partner('visitor','patron-A');p.isVisitingCard=false
 local state=merge({home('base','patron-A'),p})
 eq(state.cards.visitor.is_partner,false);eq(state.cards.visitor.home_card_id,nil);eq(state.cards.visitor.name,'Library card')
end)
test('Home-card renames and removals update displayed partner attribution',function()
 local state=merge({home('base','patron-A','Old'),partner('visitor','patron-A')})
 state=M.merge(state,response({home('base','patron-A','New'),partner('visitor','patron-A')}),2)
 contains(M.card_attribution(state,'visitor'),'New')
 state=M.merge(state,response({partner('visitor','patron-A')}),3)
 eq(state.cards.base,nil);eq(state.cards.visitor.home_card_id,nil);eq(M.card_attribution(state,'visitor'),nil)
 eq(state.cards.visitor.name,'Partner card')
end)
test('A cached partner with an unavailable home remains accurately labelled',function()
 local state=merge({home('base','patron-A'),partner('visitor','patron-A')})
 state.cards.base=nil
 eq(M.card_attribution(state,'visitor'),nil);eq(M.card_label(state,'visitor'),'Partner Library · Partner card')
end)
test('Invalid cached self-links and partner cycles cannot attribute another partner as home',function()
 local state=merge({partner('one','unknown'),partner('two','other')})
 state.cards.one.home_card_id='one';eq(M.card_attribution(state,'one'),nil)
 state.cards.one.home_card_id='two';state.cards.two.home_card_id='one';eq(M.card_attribution(state,'one'),nil)
end)
test('Partner attribution keeps custom names and masks default card-number labels',function()
 local h=home('base','patron-A','X123456789');h.username=h.cardName
 local p=partner('visitor','patron-A');p.cardName='Shared access'
 local state=merge({h,p});eq(state.cards.visitor.name,'Shared access');contains(M.card_label(state,'visitor'),'Partner card · Shared access')
 contains(M.card_attribution(state,'visitor'),'Card ••••6789')
 assert(not M.card_label(state,'visitor'):find(h.username,1,true))
end)
test('Patron-link and account credentials never enter reduced shelf persistence',function()
 local h=home('base','private-patron-identity');h.accounts={{secret='private-account'}};h.username='private-login'
 local p=partner('visitor','private-patron-identity');p.homeLibraryILSName='private-ils';p.accounts={{pin='private-pin'}}
 local state=merge({h,p});local encoded=J.encode(state)
 for _,secret in ipairs({'private-patron-identity','private-account','private-login','private-ils','private-pin','homeLibraryPUID','"puid"'}) do assert(not encoded:find(secret,1,true),secret) end
 eq(state.cards.visitor.home_card_id,'base')
end)
test('Cached generic partner names are sanitized without changing a custom name',function()
 local state={cards={a={name='Library card',is_partner=true},b={name='Custom',is_partner=true}}}
 assert(M.sanitize(state));eq(state.cards.a.name,'Partner card');eq(state.cards.b.name,'Custom')
end)
test('Borrow reconciliation keeps a home loan separate from the same title on a partner card',function()
 local raw=loan('visitor');raw.isAvailable=true
 local state=merge({home('base','patron-A'),partner('visitor','patron-A')},{loan('base')},{raw})
 local hold=state.holds['visitor:book'];eq(B.find_loan(state,hold),nil)
 fails(function() M.import_borrowed(state,loan('base'),hold) end,'unexpected loan')
 local updated,created=M.import_borrowed(state,loan('visitor'),hold)
 eq(created.card_id,'visitor');assert(updated.loans['base:book']);assert(updated.loans['visitor:book'])
end)
end
