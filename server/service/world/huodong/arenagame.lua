--import module
local skynet = require "skynet"
local global  = require "global"
local extend = require "base.extend"
local interactive = require "base.interactive"
local record = require "public.record"

local gamedefines = import(lualib_path("public.gamedefines"))
local huodongbase = import(service_path("huodong.huodongbase"))
local loaditem = import(service_path("item/loaditem"))
local analy = import(lualib_path("public.dataanaly"))

function NewHuodong(sHuodongName)
    return CHuodong:New(sHuodongName)
end

CHuodong = {}
CHuodong.__index = CHuodong
CHuodong.m_sTempName = "比武场"
CHuodong.m_SID = 1002
inherit(CHuodong, huodongbase.CHuodong)

GAME_START = 1
GAME_OVER = 2

function CHuodong:New(sHuodongName)
    local o = super(CHuodong).New(self, sHuodongName)
    o.m_Status = GAME_OVER
    o.m_iScheduleID = 2003
    o.m_TopRecord = {}  -- 对战记录
    o.m_ArenaTime = 1*3600
    return o
end


function CHuodong:NeedSave()
    return true
end

function CHuodong:Save()
    local mData = {}
    mData.show = self.m_TopRecord
    return mData
end

function CHuodong:Load(mData)
    mData = mData or {}
    self.m_TopRecord = mData.show or {}
end

function CHuodong:MergeFrom(mFromData)
    -- 可抛弃数据
    return true
end


function CHuodong:InHuodongTime()
    return self.m_Status == GAME_START
end


function CHuodong:IsClose()
    local oWorldMgr = global.oWorldMgr
    return oWorldMgr:IsClose("arenagame")
end


function CHuodong:OnLogout(oPlayer)
    if oPlayer.m_InArenaGameMatch == "arenagame" then
        self:_CheckInMatch(oPlayer,1)
    end
end

function CHuodong:OnDisconnected(oPlayer)
    if oPlayer.m_InArenaGameMatch == "arenagame" then
        self:_CheckInMatch(oPlayer,1)
    end
    local oWar = oPlayer.m_oActiveCtrl:GetNowWar()
    if oWar and oWar.m_FightIdx == 14008 then
        local mArgs = {
            war_result = 2
        }
        oWar:TestCmd("warend",oPlayer:GetPid(),mArgs)
    end
end

function CHuodong:OnLogin(oPlayer,reenter)
    self:RefreshLeftTime(oPlayer)
    if oPlayer.m_InArenaGameMatch == "arenagame" then
        self:_CheckInMatch(oPlayer,1)
    end
    if not reenter then
        self:WeekReward(oPlayer)
    end
end

function CHuodong:RefreshLeftTime(oPlayer)
    if self.m_Status ~= GAME_START then
        return
    end
    local iLeft = math.max(self.m_StartTime + self.m_ArenaTime - get_time(),1)
    local mNet = {left=iLeft}
    if oPlayer then
        oPlayer:Send("GS2CArenaLeftTime",mNet)
    else
        local mData = {
            message = "GS2CArenaLeftTime",
            type = gamedefines.BROADCAST_TYPE.WORLD_TYPE,
            id = 1,
            data = mNet,
            exclude = {}
        }
        interactive.Send(".broadcast","channel","SendChannel",mData)
    end
end

function CHuodong:NewHour(iWeekDay, iHour)
    local oWorld = global.oWorldMgr
    if iWeekDay == 1 then
        if iHour == 0 then
            self:RewardTop10()
            -- 临时这样处理,需优化
            for pid,obj in pairs(oWorld:GetOnlinePlayerList()) do
                self:WeekReward(obj)
            end
        end
    end

    local mOpenDay = self:GetConfigValue("open_day")
    if table_in_list(mOpenDay,iWeekDay) then
        if iHour == self:GetConfigValue("start_time_1")then
            self:GameStart()
        end
    else
        self:CleanTopRank()
    end

end


function CHuodong:CleanTopRank()
    local iNow = self:GetDebugTime()
    local iTimeOut = 7*24*3600
    for sStage,mRecordList in pairs(self.m_TopRecord) do
        for key,mUnit in pairs(mRecordList) do
            if iNow - mUnit.time > iTimeOut then
                table.remove(mRecordList,key)
            end
        end
    end
    self:Dirty()
end

function CHuodong:WeekReward(oPlayer)
    local iTime = self:GetDebugTime()
    local iWeekNo = get_weekno(iTime)
    local mArena = self:GetArenaData(oPlayer)
    local ino = iWeekNo - (mArena.weekno or 0 )
    local iPlay = mArena.play or 0
    local mData = self:ArenaData()
    local iScore = oPlayer:ArenaScore()
    local iState = self:ArenaStage(iScore)

    local iOldSec = mArena.time or 0
    if mArena.reward and iOldSec == mArena.reward then
        return
    end


    local mLog = {
        pid = oPlayer:GetPid(),
        point = oPlayer:ArenaScore(),
        week = iWeekNo,
        lastweek = (mArena.weekno or 0),
        stage = iState,
        }
    record.user("arenagame","week_reward",mLog)
    if iPlay > 0 and (ino > 0 and ino <= 3) then
        local iSec = self:GetDebugTime()
        if iSec - iOldSec < 15*3600*24 then
            mArena.reward = iOldSec
            self:SetArenaData(oPlayer,mArena)
            self:CreateWeekReward(oPlayer,iState)
        end
    end
    local oTitleMgr = global.oTitleMgr
    if ino~=0 then
        local iReset =1000
        local iLastState = iState - 1
        if iLastState >= 2 then
            iReset = mData[iLastState].basescore
        end
        oTitleMgr:RemoveTitles(oPlayer:GetPid(),{1001,1002,1003,1004,1005,1006,1007,1008})
        oTitleMgr:CheckTitleByType(oPlayer:GetPid(),"arena")
        oPlayer:SetArenaScore(iReset)
        oPlayer.m_oThisWeek:Delete("arenamedal")
    end
end


function CHuodong:CreateWeekReward(oPlayer,iState)
    local mData = self:ArenaData()
    local mRewardList = mData[iState].week_rewardlist
    local oMailMgr = global.oMailMgr
    local info = oMailMgr:GetMailInfo(8)
    info.context = string.gsub(info.context,"$state",tostring(iState))
    self:RewardListByMail(oPlayer:GetPid(),mRewardList,{mailinfo=info})
end

function CHuodong:GetDebugTime()
    return global.oWorldMgr:GetNowTime()
end

function CHuodong:RewardTop10()
    local mRequest = {
    data = {pid=0,},
    respond = 1,
    rank_name = "arenagame",
    }
    interactive.Request(".rank","rank","GetExtraRankData",mRequest,function(mRecord,mData)
            self:_RewardTop10(mData.data)
        end)
end

function CHuodong:_RewardTop10(mData)
    local top20 = mData.top20 or {}
    self:Dirty()
    for i=1,10 do
        local mUnit = top20[i]
        if mUnit then
            local mLog = {
            pid = mUnit.pid,
            rank = i,
            }
            record.user("arenagame","week_rank",mLog)
            self:RewardSingleTop(mUnit.pid,i)
        end
    end

    local oTitleMgr = global.oTitleMgr
    for _,mUnit in pairs(top20) do
        local pid = mUnit.pid
        local rank = mUnit.rank
        local title
        if rank == 1 then
            title = 1009
        elseif rank == 2 then
            title = 1010
        elseif rank == 3 then
            title = 1011
        end
        if rank <= 3 then
            oTitleMgr:ForceAddTitle(pid,title)
        end
    end
end

function CHuodong:RewardSingleTop(pid,iRank)
    -- local oMailMgr = global.oMailMgr
    -- local info = table_deep_copy(oMailMgr:GetMailInfo(7))
    -- local res = require "base.res"
    -- local mData = res["daobiao"]["arena"]["top"]
    -- local mRewardList
    -- for idx,m in pairs(mData) do
    --     local mR = m["range"]
    --     if mR["min"] <= iRank and iRank <=mR["max"] then
    --         mRewardList = m["reward_list"]
    --         break
    --     end
    -- end
    -- local iReward = iRank
    -- if iReward >3 then
    --     iReward = 4
    -- end
    -- info.context = string.format(info.context,iRank)
    -- self:RewardListByMail(pid,mRewardList,{mailinfo=info})
end


function CHuodong:GetArenaData(oPlayer)
    return oPlayer.m_oBaseCtrl:GetData("ArenaData",{})
end

function CHuodong:SetArenaData(oPlayer,mData)
    oPlayer.m_oBaseCtrl:SetData("ArenaData",mData)
end

function CHuodong:AddArenaPlay(oPlayer,iCnt)
    local mArena = self:GetArenaData(oPlayer)
    mArena.play = (mArena.play or 0 ) +iCnt
    mArena.weekno = get_weekno(self:GetDebugTime())
    mArena.time = self:GetDebugTime()
    self:SetArenaData(oPlayer,mArena)
    oPlayer.m_oTaskCtrl:AddTeachTaskProgress(30009,iCnt)
    return mArena.play
end


function CHuodong:SendMatch(sFun,mData,backfunc)
    mData.name = "arenagame"
    if not backfunc then
        interactive.Send(".recommend","match",sFun,mData)
    else
        mData.respond = 1
        interactive.Request(".recommend","match",sFun,mData,backfunc)
    end
end

function CHuodong:GameStart()
    local oNotifyMgr = global.oNotifyMgr
    if self.m_Status ~= GAME_START then
        record.info("arenagame.gamestart")
        self:SendMatch("CleanCach",{})
        self:SendMatch("StartMatch",{data={time=500,limit=50}})
        self.m_Status = GAME_START
        self.m_StartTime = get_time()
        self:DelTimeCb("_GameOver1")
        self:AddTimeCb("_GameOver1",self.m_ArenaTime*1000,function ()
            self:GameOver()
            end)
        oNotifyMgr:SendPrioritySysChat("arena_start",self:GetTextData(1013),1)
        self:SetHuodongState(gamedefines.SCHEDULE_TYPE.GAME_START)
        self:RefreshLeftTime()
    end
end

function CHuodong:GameOver()
    local oNotifyMgr = global.oNotifyMgr
    local oWorldMgr = global.oWorldMgr
    if self.m_Status == GAME_START then
        record.info("arenagame.gameover")
        self:DelTimeCb("_GameOver1")
        self:SendMatch("CleanCach",{})
        self:SendMatch("StopMatch",{})
        self.m_Status = GAME_OVER
        self:SetHuodongState(gamedefines.SCHEDULE_TYPE.GAME_OVER)
        oNotifyMgr:SendPrioritySysChat("arena_end",self:GetTextData(1014),1)
        local sNotify = self:GetTextData(1011)
        for k,obj in pairs(oWorldMgr:GetOnlinePlayerList()) do
            if obj.m_InArenaGameMatch == "arenagame" or obj.m_InArenaGame then
                self:_CheckInMatch(obj,1,sNotify)
            end
        end

    end
end

function CHuodong:OpenArenaUI(oPlayer)
    local oWorldMgr = global.oWorldMgr
    local pid = oPlayer:GetPid()
    local mRequest = {
    data = {pid=oPlayer:GetPid()},
    respond = 1,
    rank_name = "arenagame",
    }
    interactive.Request(".rank","rank","GetExtraRankData",mRequest,function(mRecord,mData)
        local oPlayer = oWorldMgr:GetOnlinePlayerByPid(pid)
        if oPlayer then
            self:_OpenArenaUI(oPlayer,mData.data)
        end
        end)
end

function CHuodong:_OpenArenaUI(oPlayer,mData)
    local bWatch = false
    if table_count(self.m_TopRecord) > 0 then
        bWatch = true
    end
    local mNet = {
        arena_point = oPlayer:ArenaScore(),
        weeky_medal = oPlayer.m_oThisWeek:Query("arenamedal",0),
        open_watch = bWatch,
        rank = mData.rank,
        }
    local mRankInfo = mData.top20 or {}

    mNet.rank_info = mRankInfo
    oPlayer:Send("GS2COpenArena",mNet)
end


function CHuodong:ClientStartMath(oPlayer,iResult)
    oPlayer:Send("GS2CArenaStartMath",{result=iResult})
end

function CHuodong:EnterMatch(oPlayer)
    if not self:ValidEnterMatch(oPlayer) then
        self:ClientStartMath(oPlayer,0)
        return
    end
    local oWorldMgr = global.oWorldMgr
    local pid = oPlayer:GetPid()
    local iScore = oPlayer:ArenaScore()
    local iStage = self:ArenaStage(iScore)
    local mArena = self:GetArenaData(oPlayer)
    if oPlayer.m_TestAiBattle or iScore <= 800 or (mArena.play or 0) < 1 then
        oPlayer.m_TestAiBattle = nil
        self:ClientStartMath(oPlayer,1)
        self:ReadyRobotWar(oPlayer)
        return
    end
    oPlayer.m_InArenaGameMatch = "arenagame"
    self:SendMatch("EnterMatch",{id=oPlayer:GetPid(),data={score =iScore,stage =iStage,}})
    self:ClientStartMath(oPlayer,1)
end

function CHuodong:_CheckInMatch(oPlayer,iLeave,sNotify)
    local oNotify = global.oNotifyMgr
    oPlayer:DelTimeCb("arena_checkinmatch")
    oPlayer.m_InArenaGameMatch = nil
    if iLeave == 1 then
        self:SendMatch("LeaveMatch",{id=oPlayer:GetPid(),})
        self:ClientStartMath(oPlayer,0)
    end
    if sNotify and sNotify~="" then
         oNotify:Notify(oPlayer:GetPid(),sNotify)
    end
end


function CHuodong:LeaveMatch(oPlayer)
    self:_CheckInMatch(oPlayer,1)
end

function CHuodong:ValidEnterMatch(oPlayer)
    local oNotifyMgr = global.oNotifyMgr
    local oWorldMgr = global.oWorldMgr
    local iGrade = oWorldMgr:QueryControl("arenagame","open_grade")
    if not self:InHuodongTime() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1005))
        return false
    elseif oPlayer:HasTeam() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1008))
        return false
    elseif self:IsClose() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1007))
        return false
    elseif oPlayer:GetGrade()< iGrade then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1002))
        return false
    elseif oPlayer.m_InArenaGame then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1009))
        return false
    elseif oPlayer.m_InArenaGameMatch then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1009))
        return false
    elseif table_count(oPlayer.m_oPartnerCtrl:GetFightPartner()) ~=4  or not oPlayer.m_oPartnerCtrl:GetMainPartner() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1010))
        return false
    end
    return true
end

function CHuodong:MatchResult(fightlist,mInfo)
    if self.m_TestMatch then
        self:TestMatchResult(fightlist,mInfo)
        return
    end
    local oWorldMgr = global.oWorldMgr
    local oNotify = global.oNotifyMgr
    local oWarMgr = global.oWarMgr
    for _,mFight in pairs(fightlist) do
        self:ReadyPVPWar(mFight[1],mFight[2])
    end
end

function CHuodong:ReadyPVPWar(iTarget1,iTarget2)
    local oWorldMgr = global.oWorldMgr
    local oNotify = global.oNotifyMgr
    local oWarMgr = global.oWarMgr

    local oTarget1 = oWorldMgr:GetOnlinePlayerByPid(iTarget1)
    local oTarget2 = oWorldMgr:GetOnlinePlayerByPid(iTarget2)
    local bStartFight = true
    if not self:ValidEnterWar(oTarget1,oTarget2)  then
        bStartFight = false
    end
    if not self:ValidEnterWar(oTarget2,oTarget1) then
        bStartFight = false
    end
    self:_CheckInMatch(oTarget1,0)
    self:_CheckInMatch(oTarget2,0)
    if bStartFight then
        oTarget1.m_InArenaGame = {target = iTarget2}
        oTarget2.m_InArenaGame = {target = iTarget1}
        self:RefreshReadyUI(oTarget1,iTarget2)
        self:RefreshReadyUI(oTarget2,iTarget1)
    else
        if oTarget1 then self:ClientStartMath(oTarget1,0) end
        if oTarget2 then self:ClientStartMath(oTarget2,0) end
    end

end

function CHuodong:ValidEnterWar(oPlayer,oTarget)
    local oNotifyMgr = global.oNotifyMgr
    if not oPlayer then
        return false
    elseif not self:InHuodongTime() then
        return false
    elseif self:IsClose() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1007))
        return false
    elseif not oTarget then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1006))
        return false
    elseif oPlayer:GetNowWar() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1003))
        return false
    elseif oTarget:GetNowWar() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1004))
        return false
    elseif oPlayer:HasTeam() then
        oNotifyMgr:Notify(oPlayer:GetPid(),self:GetTextData(1008))
        return false
    end
    return true
end

function CHuodong:PackRankInfo(oPlayer)
    return {
        pid = oPlayer:GetPid(),
        name = oPlayer:GetName(),
        shape = oPlayer:GetModelInfo().shape,
        rank = 0,
        point = oPlayer:ArenaScore(),
        praise = 0,
        }
end


function CHuodong:RefreshReadyUI(oPlayer,iTarget,mPack)
    local oWorldMgr = global.oWorldMgr
    local pid = oPlayer:GetPid()

    oPlayer:DelTimeCb("arena_CheckReady")
    oPlayer:AddTimeCb("arena_CheckReady", 3*1000,function ()
        local oPlayer = oWorldMgr:GetOnlinePlayerByPid(pid)
        if oPlayer then
            self:_CheckReadyStatus(oPlayer)
        end
        end)

    if not mPack then
        local oTarget = oWorldMgr:GetOnlinePlayerByPid(iTarget)
        if oTarget then
            local mNet = {
            rankInfo = self:PackRankInfo(oTarget),
            }
            oPlayer:Send("GS2CArenaMatch",mNet)
        end
    else
        oPlayer:Send("GS2CArenaMatch",{rankInfo=mPack})
    end
end

function CHuodong:_CheckReadyStatus(oPlayer)
    oPlayer:DelTimeCb("arena_CheckReady")
    local oWorldMgr = global.oWorldMgr
    if oPlayer.m_InArenaGame then
        local iTarget = oPlayer.m_InArenaGame.target or 0
        local oTarget = oWorldMgr:GetOnlinePlayerByPid(iTarget)
        if oTarget then
            oTarget:DelTimeCb("arena_CheckReady")
        end
        if oPlayer.m_InArenaGame.robot then
            self:StartRobotWar(oPlayer)
        else
            self:StartPVPWar(oPlayer:GetPid(),iTarget)
        end
    end
end

function CHuodong:StartPVPWar(iTarget1,iTarget2)
    local oWorldMgr = global.oWorldMgr
    local oNotify = global.oNotifyMgr
    local oWarMgr = global.oWarMgr

    local oTarget1 = oWorldMgr:GetOnlinePlayerByPid(iTarget1)
    local oTarget2 = oWorldMgr:GetOnlinePlayerByPid(iTarget2)
    local bStartFight = true
    if not self:ValidEnterWar(oTarget1,oTarget2)  then
        bStartFight = false
    end
    if not self:ValidEnterWar(oTarget2,oTarget1) then
        bStartFight = false
    end

    if bStartFight then
        local iGameTarget1 = oTarget1.m_InArenaGame.target
        local iGameTarget2 = oTarget2.m_InArenaGame.target
        if iGameTarget1 ~= iTarget2 then
            bStartFight = false
        end
        if iGameTarget2 ~= iTarget1 then
            bStartFight = false
        end
    end
    if bStartFight then
        local mArg = {
        remote_war_type="arenagame",
        war_type = gamedefines.WAR_TYPE.ARENA_TYPE,
        remote_args = { war_record = 1},
        pvpflag = 1,
        }
        local oWar = oWarMgr:CreateWar(mArg)
        oWar:SetData("close_auto_skill",true)

        local iScore1 = oTarget1:ArenaScore()
        local iScore2 = oTarget2:ArenaScore()
        oTarget1.m_InArenaGame = nil
        oTarget2.m_InArenaGame = nil
        local iCnt1 = self:AddArenaPlay(oTarget1,1)
        local iCnt2 = self:AddArenaPlay(oTarget2,1)
        oTarget1:Send("GS2CArenaFight",{})
        oTarget2:Send("GS2CArenaFight",{})

        local mWarRecord = {}
        local mUint1 = {
        name = oTarget1:GetName(),
        point = iScore1,
        partner = {},
        grade = oTarget1:GetGrade(),
        shape = oTarget1:GetModelInfo().shape,
        }
        mWarRecord[db_key(oTarget1:GetPid())] = mUint1
        local mUint2 = {
        pid = oTarget2:GetPid(),
        name = oTarget2:GetName(),
        point = iScore2,
        partner = {},
        grade = oTarget2:GetGrade(),
        shape = oTarget2:GetModelInfo().shape,
        }
        mWarRecord[db_key(oTarget2:GetPid())] = mUint2

        local mLog = {
        pid1 = oTarget1:GetPid(),
        point1 = iScore1,
        name1 = oTarget1:GetName(),
        count1 = iCnt1,

        pid2 = oTarget2:GetPid(),
        point2 = iScore2,
        name2 = oTarget2:GetName(),
        count2 = iCnt2,
        }
        record.user("arenagame", "start_pvp",mLog)


        local iWarID = oWar:GetWarId()
        local mArg = {camp_id = 1,}
        oWarMgr:EnterWar(oTarget1, iWarID, mArg, true)

        local mArg = {camp_id = 2,}
        oWarMgr:EnterWar(oTarget2, iWarID, mArg, true)

        oWarMgr:SetWarEndCallback(oWar:GetWarId(),function (mArg)
            local oWar = oWarMgr:GetWar(iWarID)
            oWar.m_WarRecord = {fight = mWarRecord}
            self:OnPVPWarEnd(oWar,iTarget1,iTarget2,iScore1,iScore2,mArg)
            end)
        oWarMgr:StartWarConfig(iWarID)
        oTarget1.m_oThisWeek:Add("EqualArena_Play",1)
        oTarget2.m_oThisWeek:Add("EqualArena_Play",1)
    else
        if oTarget1 then
            self:ClientStartMath(oTarget1,0)
            oTarget1.m_InArenaGame = nil
        end
        if oTarget2 then
            self:ClientStartMath(oTarget2,0)
             oTarget2.m_InArenaGame = nil
        end
    end
end

function CHuodong:ArenaData()
    local res = require "base.res"
    return res["daobiao"]["arena"]["arena"]
end

-- ELO - (para[min(La,Lb)]*(if(a取胜?1;0)-1/(1+10^((Tb-Ta)/400)),0)
-- Ta is Winner
function CHuodong:ScoreCalculator(iTa,iTb,iWin)
    local mData = self:ArenaData()
    local iLa = self:ArenaStage(iTa)
    local iLb = self:ArenaStage(iTb)
    local iPara = mData[math.min(iLa,iLb)]["para"]
    local fY=1/(1+10^((iTb-iTa)/400))
    if iWin == 1 then
        fY = 1 - fY
    end
    -- 目前双方增减积分相同
    local fA = iPara*fY
    if fA%1 > 0.5 then
        fA = fA +1
    end
    local iA = math.max(math.floor(fA),0)
    return iA,iA
end

function CHuodong:ArenaStage(iScore)
    local mData = self:ArenaData()
    for i=#mData,1,-1 do
        local mInfo = mData[i]
        if iScore >= mInfo.basescore then
            return mInfo["id"]
        end
    end
    return 1
end

function CHuodong:ArenaInfo(iStage)
    local mData = self:ArenaData()
    return mData[iStage]
end

function CHuodong:OnPVPWarEnd(oWar,iTarget1,iTarget2,iScore1,iScore2,mArg)
    local oWorldMgr = global.oWorldMgr
    local oTarget1 = oWorldMgr:GetOnlinePlayerByPid(iTarget1)
    local oTarget2 = oWorldMgr:GetOnlinePlayerByPid(iTarget2)
    local iRewardScore,iSubScore = self:ScoreCalculator(iScore1,iScore2,mArg.win_side)
    local mRecord = oWar.m_WarRecord
    local iBout = mArg["bout"] or 0
    local mFight = mRecord.fight
    local unit1 = mFight[db_key(iTarget1)]
    local unit2 = mFight[db_key(iTarget2)]
    unit1.score = iRewardScore
    unit2.score = iSubScore

    mRecord.fid = mArg.war_film_id
    local mFightPartner = mArg.arena_partner
    local mPar1 = mFightPartner[iTarget1] or {}
    unit1.partner = mPar1
    local mPar2 = mFightPartner[iTarget2] or {}
    unit2.partner = mPar2

    local iLogScore1
    local iLogScore2

    local mResultData = {win = mArg.win_side}

    if mArg.win_side ==1 then
        mRecord.win = iTarget1
        iLogScore1 = iRewardScore
        iLogScore2 = -iRewardScore
    else
        mRecord.win = iTarget2
        iLogScore1 = -iRewardScore
        iLogScore2 = iRewardScore
    end

    local sName1 = ""
    local sName2 = ""
    local iLogPScore1 = -1
    local iLogPScore2 = -1

    mRecord["camp"] = {iTarget1,iTarget2}
    if oTarget1 then
        sName1 = oTarget1:GetName()
        iLogPScore1 = oTarget1:ArenaScore() + iLogScore1
        oTarget1:AddSchedule("arenagame")
        self:RecordData(oTarget1,mRecord)
    end

    if oTarget2 then
        sName2 = oTarget2:GetName()
        iLogPScore2 = oTarget2:ArenaScore() + iLogScore2
        oTarget2:AddSchedule("arenagame")
        self:RecordData(oTarget2,mRecord)
    end

    mResultData["data"] = {}
    table.insert(mResultData["data"],{pid = iTarget1,name =unit1["name"],shape=unit1["shape"],camp=1})
    table.insert(mResultData["data"],{pid = iTarget2,name =unit2["name"],shape=unit2["shape"],camp=2})
    local mLog = {
        pid1= iTarget1,
        addpoint1 = iLogScore1,
        name1 = sName1,
        point1 = iLogPScore1,

        pid2 = iTarget2,
        name2 = sName2,
        addpoint2 = iLogScore2,
        point2 = iLogPScore2,

        win = mRecord.win,
        }

    record.user("arenagame","end_arena",mLog)


    if iBout > 3 then
        self:CollectWarRecord(mRecord)
    end
    if mArg.win_side ==1 then
        if oTarget1 then self:RewardWin(oTarget1,iRewardScore,iTarget2,mRecord,mResultData) end
        if oTarget2 then self:RewardFail(oTarget2,iSubScore,iTarget1,mRecord,mResultData) end
    else
        if oTarget2 then self:RewardWin(oTarget2,iRewardScore,iTarget1,mRecord,mResultData) end
        if oTarget1 then self:RewardFail(oTarget1,iSubScore,iTarget2,mRecord,mResultData) end
    end
    self:Dirty()

    self:FilterAnalyData(oWar,oTarget1,oTarget2,mRecord.win == oTarget1:GetPid())
    self:FilterAnalyData(oWar,oTarget2,oTarget1,mRecord.win == oTarget2:GetPid())

    global.oHandBookMgr:CheckCondition("arena", nil, mArg)
end

function CHuodong:FilterAnalyData(oWar,oTarget1,oTarget2,bWin)
    local iCnt = oTarget1 and self:GetArenaData(oTarget1).play or 0
    local iPid = oTarget1:GetPid()
    local mPartner,mTargetPartner
    mPartner = self:GetPartnerTypeList(oWar,oTarget1)
    if oTarget2 then
        mTargetPartner = self:GetPartnerTypeList(oWar,oTarget2)
    end
    local iHonor = self:GetKeep(iPid,"reward_honor",0)
    local timelen = oWar:GetWarDuration()
    self:LogAnalyData(oTarget1,oTarget2,iCnt,mPartner,mTargetPartner,bWin,iHonor,timelen)
end

function CHuodong:GetPartnerTypeList(oWar,oPlayer)
    local iPid = oPlayer:GetPid()
    local mOFPartner = oWar.m_OutFightPartner or {}
    local mPartnerID = mOFPartner[iPid] or {}
    local tResult
    for partID,_ in pairs(mPartnerID) do
        local oPartner = oPlayer.m_oPartnerCtrl:GetPartner(partID)
        if oPartner then
            local iType = oPartner:SID()
            tResult = tResult or {}
            tResult[iType] = tResult[iType] or 0
            tResult[iType] = tResult[iType] + 1
        end
    end
    return tResult
end

function CHuodong:RecordRank(oPlayer)
    local mInfo = {
    point = oPlayer:ArenaScore(),
    pid = oPlayer:GetPid(),
    name= oPlayer:GetName(),
    shape = oPlayer:GetModelInfo().shape,
    grade = oPlayer:GetGrade(),
    school = oPlayer:GetSchool(),
    segment= self:ArenaStage(oPlayer:ArenaScore()),
    time = get_current(),
    }
    local mRank = {}
    mRank.rank_name = "arenagame"
    mRank.rank_data = mInfo
    interactive.Send(".rank","rank","PushDataToRank",mRank)
end

function CHuodong:RewardArenaMedal(oPlayer,bWin)
    local mData = self:ArenaData()
    local iLa = self:ArenaStage(oPlayer:ArenaScore())
    local mInfo = mData[iLa]
    local iWeek = mInfo.weeky_limit
    local iRewardPoint = mInfo.award_per_game
    local iNow = oPlayer.m_oThisWeek:Query("arenamedal",0)
    local sReason = "比武获胜"
    if not bWin then
        iRewardPoint = iRewardPoint//2
        sReason = "比武失败"
    end
    if iNow < iWeek then
        local iMin = math.min(iWeek-iNow,iRewardPoint)
        oPlayer:RewardArenaMedal(iMin,sReason)
        oPlayer.m_oThisWeek:Add("arenamedal",iMin)
        return iMin
    end
    return 0
end

function CHuodong:RewardWin(oPlayer,iRewardScore,iTarget,mRecord,mResultData)
    local iMedal  = self:RewardArenaMedal(oPlayer,mResultData)
    self:AddKeep(oPlayer:GetPid(), "reward_honor", iMedal)
    local oNotify = global.oNotifyMgr
    local iScore = oPlayer:ArenaScore()
    self:SendWarResult(oPlayer,iRewardScore,iMedal,mResultData)
    oPlayer:SetArenaScore(iScore+iRewardScore)
    self:RecordRank(oPlayer)
    global.oAchieveMgr:PushAchieve(oPlayer:GetPid(),"比武场连胜次数",{value=1})
    global.oAchieveMgr:PushAchieve(oPlayer:GetPid(),"比武场胜利场数",{value=1})

    local mCurrency = {}
    mCurrency[gamedefines.COIN_FLAG.COIN_MEDAL] = iMedal
    oPlayer:LogAnalyGame({}, "arena_game",{},mCurrency,{},0)
end

function CHuodong:SendWarResult(oPlayer,iScore,iMedal,mResultData)
    local mData = mResultData["data"]
    local mNet = {
            point = iScore,
            medal = iMedal,
            result = mResultData["win"],
            info = mResultData["data"],
            enemy_name = mData["name"],
            enemy_shape = mData["shape"],
            weeky_medal = oPlayer.m_oThisWeek:Query("arenamedal",0),
            currentpoint = oPlayer:ArenaScore(),
        }
    oPlayer:Send("GS2CArenaFightResult",mNet)
end


function CHuodong:RewardFail(oPlayer,iSubScore,iTarget,mRecord,mResultData)
    local oNotify = global.oNotifyMgr
    local iScore = oPlayer:ArenaScore()
    local iSetScore = math.max(iScore-iSubScore,0)
    local iMedal = self:RewardArenaMedal(oPlayer,false)
    self:SendWarResult(oPlayer,iSubScore,iMedal,mResultData)
    oPlayer:SetArenaScore(iSetScore)
    self:RecordRank(oPlayer)
    global.oAchieveMgr:ClearAchieveDegree(oPlayer:GetPid(),"比武场连胜次数")

    local mCurrency = {}
    mCurrency[gamedefines.COIN_FLAG.COIN_MEDAL] = iMedal
    oPlayer:LogAnalyGame({}, "arena_game",{},mCurrency,{},0)
end


-- PVE

function CHuodong:ReadyRobotWar(oPlayer)
    local oWorldMgr = global.oWorldMgr
    local iFid = self:ChooseRobotWar()
    local mMonster = self:GetTollGateData(iFid).monster
    local iRobotShape = 1
    local mPartner = {}
    for _,mInfo in pairs(mMonster) do
        local mid = mInfo["monsterid"]
        local mMonster = self:GetMonsterData(mid)
        local name = mMonster.name
        local iShape = mMonster.model_id
        if name == "$ainame" then
            iRobotShape = iShape
        elseif #mPartner < 4 then
            table.insert(mPartner,iShape)
        end
    end
    local mRobot = {
    name = oWorldMgr:RandomName() ,
    pid = 0 ,
    shape = iRobotShape,
    rank = 1000,
    point = 974 + math.random(51) ,
    praise = 0 ,
    partner = mPartner,
    fid = iFid,
    grade = oPlayer:GetGrade(),
    }
    local mRecord= {
        name = oPlayer:GetName(),
        point = oPlayer:ArenaScore(),
        partner = {},
        grade = oPlayer:GetGrade(),
        shape = oPlayer:GetModelInfo().shape,
        }
    oPlayer.m_InArenaGame = {robot = mRobot,myrecord = mRecord}
    local mNet = {
    name = mRobot.name ,
    pid = 0 ,
    shape = mRobot.shape,
    rank = mRobot.rank,
    point = mRobot.point ,
    praise = mRobot.praise ,
    }
    self:RefreshReadyUI(oPlayer,0,mNet)
    --self:StartRobotWar(oPlayer)
end

function CHuodong:CreateMonster(oWar,iMonsterIdx,npcobj, mArgs)
    local o = super(CHuodong).CreateMonster(self,oWar,iMonsterIdx,npcobj, mArgs)
    if self.m_AIName and string.find(o:GetAttr("name"),"$ainame") then
        o:SetAttr("name",self.m_AIName)
    end
    return o
end

function CHuodong:GetCreateWarArg(mArg)
    mArg.remote_war_type = "arenagame"
    mArg.war_type = gamedefines.WAR_TYPE.ARENA_TYPE
    mArg.pvpflag = 1
    return mArg
end

function CHuodong:GetRemoteWarArg()
    return {
        war_record = 1,
    }
end


function CHuodong:StartRobotWar(oPlayer)
    if not self:ValidEnterRobotWar(oPlayer) then
        oPlayer.m_InArenaGame = nil
        self:ClientStartMath(oPlayer,0)
        return
    end
    local mInfo = oPlayer.m_InArenaGame
    if mInfo then
        self.m_AIName = mInfo.robot.name
        local iWar = mInfo.robot.fid
        local oWar = self:CreateWar(oPlayer:GetPid(),nil,iWar)
        self.m_AIName = nil
        if oWar then
            oWar.m_InArenaGame = mInfo
            oPlayer.m_InArenaGame = nil
            local iCnt = self:AddArenaPlay(oPlayer,1)
            local mLog = {
            pid = oPlayer:GetPid(),
            name = oPlayer:GetName(),
            count = iCnt,
            point = oPlayer:ArenaScore(),
            robot_name = mInfo.robot.name,
            robot_point = mInfo.robot.point,
            }
            record.user("arenagame","start_robot",mLog)
        end
    end
end

function CHuodong:ValidEnterRobotWar(oPlayer)
    if not self:InHuodongTime() then
        return false
    elseif self:IsClose() then
        return false
    elseif oPlayer.m_oActiveCtrl:GetNowWar() then
        return false
    elseif oPlayer:HasTeam() then
        return false
    end
    return true
end

function CHuodong:ChooseRobotWar()
    local res = require "base.res"
    local mData = res["daobiao"]["tollgate"][self.m_sName]
    local keylist = extend.Table.keys(mData)
    return extend.Random.random_choice(keylist)
end

function CHuodong:OnWarWin(oWar, pid, npcobj, mArgs)
    local oWorldMgr = global.oWorldMgr
    local oPlayer = oWorldMgr:GetOnlinePlayerByPid(pid)
    if not oPlayer then
        return
    end
    self:OnRobotWarEnd(oWar,oPlayer,mArgs,true)
end


function CHuodong:OnWarFail(oWar, pid, npcobj, mArgs)
    local oWorldMgr = global.oWorldMgr
    local oPlayer = oWorldMgr:GetOnlinePlayerByPid(pid)
    if not oPlayer then
        return
    end
    self:OnRobotWarEnd(oWar,oPlayer,mArgs,false)
end

function CHuodong:OnRobotWarEnd(oWar,oPlayer,mArg,bWin)
    assert(oWar.m_InArenaGame,string.format("PVE arena warwin %d",oPlayer:GetPid()))
    local mRobot = oWar.m_InArenaGame.robot

    local sWarFilm = mArg.war_film_id
    local iScore2 = oPlayer:ArenaScore()
    local iScore1 = mRobot.point
    local iS1,iS2 = self:ScoreCalculator(iScore1,iScore2,mArg.win_side)
    local iSubScore = iS1
    if not bWin then
        iSubScore = iS2
    end
    local mUnit1 = oWar.m_InArenaGame.myrecord
    local mFightPartner = mArg.arena_partner
    local mPar1 = mFightPartner[oPlayer:GetPid()] or {}

    oPlayer:AddSchedule("arenagame")
    mUnit1.partner = mPar1
    mUnit1.score = iSubScore
    local mUnit2 = {
        name = mRobot.name,
        point = iScore1,
        partner = mRobot.partner,
        grade = mRobot.grade,
        shape = mRobot.shape,
        score = iSubScore,
        }
    local mRecord = {fight={[db_key(oPlayer:GetPid())] = mUnit1, ["0"] = mUnit2}}

    mRecord.fid = sWarFilm
    local iLogScore
    if bWin then
        mRecord.win = oPlayer:GetPid()
        iLogScore = iSubScore
    else
        mRecord.win = 0
        iLogScore = - iSubScore
    end

    local mLog = {
    pid1 = oPlayer:GetPid(),
    addpoint1 = iLogScore,
    point1 = iScore2 + iLogScore,
    name1 = oPlayer:GetName(),

    pid2 = 0,
    addpoint2 = 0,
    point2 = iScore1,
    name2 = mRobot.name,
    win = mRecord.win,
    }

    record.user("arenagame","end_arena",mLog)
    local mResultData = {win=1}
    if not bWin then
        mResultData["win"] = 2
    end

    mResultData["data"] = {}
    table.insert(mResultData["data"],{pid = oPlayer:GetPid(),name =mUnit1["name"],shape=mUnit1["shape"],camp=1})
    table.insert(mResultData["data"],{pid = 0,name =mUnit2["name"],shape=mUnit2["shape"],camp=2})

    if bWin then
        self:RewardWin(oPlayer,iSubScore,0,mRecord,mResultData)
    else
         self:RewardFail(oPlayer,iSubScore,0,mRecord,mResultData)
    end
    self:RecordData(oPlayer,mRecord)
    self:FilterAnalyData(oWar,oPlayer,nil,bWin)
end

function CHuodong:RecordData(oPlayer,mRecord)
    local mCopyRecord = table_deep_copy(mRecord)
    mCopyRecord.time = get_time()
    local mUnit = mCopyRecord.fight[db_key(oPlayer:GetPid())]
    if mCopyRecord.win == oPlayer:GetPid() then
        mCopyRecord.score = mUnit.score
    else
        mCopyRecord.score = - mUnit.score
    end
    local mArena = self:GetArenaData(oPlayer)
    local mRecordList = mArena.record or {}
    table.insert(mRecordList,mCopyRecord)
    mArena.record = mRecordList
    self:SetArenaData(oPlayer,mArena)
    self:CleanRecord(oPlayer)
    local mShow = mArena.show_record
    local iFid = (mShow and (mShow.fid or 0)) or 0
    if not iFid or iFid == 0 then
        for _,mData in pairs(mRecordList) do
            if tonumber(iFid) < tonumber(mData.fid) then
                iFid  = mData.fid
                mShow = mData
            end
        end
    end
    if iFid ~= 0 then
        local oProfile = oPlayer:GetProfile()
        oProfile:SetData("war_record",table_deep_copy(mShow))
    end

end


function CHuodong:CollectWarRecord(mRecord)
    local mCopyRecord = table_deep_copy(mRecord)
    mCopyRecord.time = get_time()
    local mFight = mCopyRecord["fight"]
    local iScore = 0
    for pid,mUnit in pairs(mFight) do
        if iScore < mUnit.point then
            iScore = mUnit.point
        end
    end
    mCopyRecord.maxpoint = iScore
    local sStage = db_key(self:ArenaStage(iScore))
    local mRecordList = self.m_TopRecord[sStage] or {}
    local iLen = #mRecordList
    table.insert(mRecordList,mCopyRecord)
    table.sort(mRecordList,function (a1,a2)
            return a1.maxpoint > a2.maxpoint
            end)

    local mMaxTable = {mRecordList[1],mRecordList[2],}
    table.sort(mRecordList,function (a1,a2)
            return a1.time > a2.time
            end)

    local mNewCopyRecord = {}
    for i,mRecord in ipairs(mRecordList) do
        local fid = mRecord.fid
        if fid ~= mMaxTable[1].fid then
            if mMaxTable[2]  and fid ~= mMaxTable[2].fid then
                table.insert(mNewCopyRecord,mRecord)
            end
        end
    end
    if mMaxTable[1] then
        table.insert(mNewCopyRecord,1,mMaxTable[1])
    end

    if mMaxTable[2] then
        table.insert(mNewCopyRecord,2,mMaxTable[2])
    end
    if #mNewCopyRecord>= 10 then
        table.remove(mNewCopyRecord,#mNewCopyRecord)
    end
    self.m_TopRecord[sStage] = mNewCopyRecord
    self.m_TopRecordPack = nil
    self:Dirty()
end

function CHuodong:CleanRecord(oPlayer)
    local mArena = self:GetArenaData(oPlayer)
    local mRecordList = mArena.record or {}
    local iNow = get_time()
    local iTimeout = 72*3600
    for i= 1,#mRecordList do
        local mData = mRecordList[1]
        if not mData then
            break
        end
        if iNow - mData.time < iTimeout then
            break
        end
        table.remove(mRecordList,1)
    end
    local iLimit = 30
    if #mRecordList > iLimit then
        table.remove(mRecordList,1)
    end
    mArena.record = mRecordList
    self:SetArenaData(oPlayer,mArena)
    return mRecordList
end

function CHuodong:PackHistoryInfo(mData)
    local mFight = mData.fight
    local mRecord = {}
    local mFightList = {}
    local mCamp = mData["camp"]
    if not mCamp then
        mCamp = {}
        for pid,mR in pairs(mFight) do
            pid = tonumber(pid)
            table.insert(mCamp,pid)
        end
    end
    for iCamp,pid in ipairs(mCamp) do
        local skey = db_key(pid)
        local mR = mFight[skey]

        local mPartner = {}
        for pid,shape in pairs(mR.partner or {}) do
            table.insert(mPartner,shape)
        end
        local mPlayerInfo = {
                    name = mR.name,
                    partner = table_to_int_key(mPartner),
                    point = mR.point,
                    grade = mR.grade,
                    shape = mR.shape,
                    pid = pid,
                }
        table.insert(mFightList,mPlayerInfo)
        mRecord.playerInfo = mFightList
        mRecord.fid = tostring(mData.fid or 0)
        mRecord.win = mData.win
        mRecord.score = mData.score
        mRecord.time = mData.time
        end
    return mRecord
end

function CHuodong:OpenArenaHistory(oPlayer)
    self:CleanRecord(oPlayer)
    local mArena = self:GetArenaData(oPlayer)
    local mRecordList = mArena.record or {}
    local mHistory_info = {}

    for _,mData in ipairs(mRecordList) do
        table.insert(mHistory_info,self:PackHistoryInfo(mData))
    end
    local mShow = mArena.show_record
    local mNetShow = {}
    if mShow and table_count(mShow)>0 then
        mNetShow = self:PackHistoryInfo(mShow)
    end

    local mNet ={
    history_info = mHistory_info,
    history_onshow = mNetShow,
    }
    oPlayer:Send("GS2CArenaHistory",mNet)
end

function CHuodong:SetShowRecord(oPlayer,fid)
    local mArena = self:GetArenaData(oPlayer)
    local mRecordList = mArena.record or {}
    local mRecord
    for _,mData in ipairs(mRecordList) do
        if mData.fid == fid then
            mRecord = mData
            break
        end
    end
    if not mRecord then
        return
    end
    local mCopy = table_deep_copy(mRecord)
    local mArena = self:GetArenaData(oPlayer)
    mArena.show_record = mCopy
    self:SetArenaData(oPlayer,mArena)
    oPlayer:GetProfile():SetData("war_record",table_deep_copy(mCopy))
    local oNotifyMgr = global.oNotifyMgr
    oNotifyMgr.Notify(oPlayer:GetPid(),"设定成功")
    oPlayer:Send("GS2CArenaSetShowing",{fid=fid})
end

function CHuodong:ShowTopRecord(oPlayer)
    local mNet
    if not self.m_TopRecordPack then
        mNet = {}
        mNet.grade_record_info = {}
        for sStage,mRecordList in pairs(self.m_TopRecord) do
            local mData={}
            mData.stage = tonumber(sStage)
            mData.history_info = {}
            for i=1,5 do
                local mRecord = mRecordList[i]
                if not mRecord then
                    break
                end
                table.insert(mData.history_info,self:PackHistoryInfo(mRecord))
            end
            table.insert(mNet.grade_record_info,mData)
        end
        self.m_TopRecordPack = mNet
    else
        mNet = self.m_TopRecordPack
    end
    oPlayer:Send("GS2CArenaOpenWatch",mNet)
end

function CHuodong:LogAnalyData(oPlayer,oTarget,iCnt,mPartner,mTPartner,bWin,iHonor,timelen)
    local mLog = oPlayer:GetPubAnalyData()
    mLog["operation"] = 1
    mLog["turn_times"] = iCnt or 0
    mLog["partner_detail"] = analy.datajoin(mPartner)
    mLog["match_role_id_detail"] = "robot"
    if oTarget then
        mLog["match_role_id_detail"] = string.format("%d+%d+%d",oTarget:GetPid(),oTarget:GetSchool(),oTarget:GetGrade())
    end
    mLog["match_partner_detail"] = analy.datajoin(mTPartner)
    mLog["win_mark"] = bWin
    mLog["reward_honor"] = iHour
    mLog["total_honor"] = oPlayer:ArenaMedal()
    mLog["consume_time"] = timelen
    analy.log_data("arena",mLog)
end




function CHuodong:TestOP(oPlayer,iFlag,...)
    local args = {...}
    local oNotify = global.oNotifyMgr
    local oWorldMgr = global.oWorldMgr
    local pid = oPlayer:GetPid()
    local oChatMgr = global.oChatMgr
    if iFlag == 100 then
        oChatMgr:HandleMsgChat(oPlayer,"101-开启比武场")
        oChatMgr:HandleMsgChat(oPlayer,"102-关闭比武场")
        oChatMgr:HandleMsgChat(oPlayer,"103-进入机器人战斗,iScore ,机器人分数")
        oChatMgr:HandleMsgChat(oPlayer,"104-与id玩家立刻进行比武")
        oChatMgr:HandleMsgChat(oPlayer,"105-积分计算 iTa,iTb")
        oChatMgr:HandleMsgChat(oPlayer,"107-设定参加比武次数")
        oChatMgr:HandleMsgChat(oPlayer,"108-清除排行版发放记录,清除自己的周领取记录")
        oChatMgr:HandleMsgChat(oPlayer,"109-模拟周一0点")
        oChatMgr:HandleMsgChat(oPlayer,"110-clean arena data")
        oChatMgr:HandleMsgChat(oPlayer,"111-设定测试时间")
        oChatMgr:HandleMsgChat(oPlayer,"112 - 周一12点")
        oChatMgr:HandleMsgChat(oPlayer,"113 - 查看自己的比武数据")
    elseif iFlag == 101 then
        self:GameStart()
    elseif iFlag == 102 then
        self:GameOver()
    elseif iFlag == 103 then
        self:StartRobotWar(oPlayer)
    elseif iFlag == 104 then
        local oWorldMgr = global.oWorldMgr
        local iTarget1 = oPlayer:GetPid()
        local iTarget2 = tonumber(args[1])
        local oTarget1 = oWorldMgr:GetOnlinePlayerByPid(iTarget1)
        local oTarget2 = oWorldMgr:GetOnlinePlayerByPid(iTarget2)
        oTarget1.m_InArenaGame = {target = iTarget2,}
        oTarget2.m_InArenaGame = {target = iTarget1,}
        self:StartPVPWar(iTarget1,iTarget2)
    elseif iFlag == 105 then
        local iScore1,iScore2,iWin = tonumber(args[1]),tonumber(args[2]),tonumber(args[3])
        local iA,iB = self:ScoreCalculator(iScore1,iScore2,iWin)
        local msg = string.format("add:%d , sub:%d",iA,iB)
        record.info(msg)
        oNotify:Notify(pid,msg)
    elseif iFlag == 107 then
        local iPlay = tonumber(args[1])
        local mArena = self:GetArenaData(oPlayer)
        mArena.play = iPlay - 1
        self:SetArenaData(oPlayer,mArena)
        self:AddArenaPlay(oPlayer,1)
        oNotify:Notify(pid,string.format("设置次数为 %d",iPlay))
        self:RecordRank(oPlayer)
    elseif iFlag == 108 then
        local mArena = self:GetArenaData(oPlayer)
        mArena.weekno = get_weekno() - 1
        self:SetArenaData(oPlayer,mArena)
        oNotify:Notify(oPlayer:GetPid(),"清理完毕")
    elseif iFlag == 109 then
        self:NewHour(1,0)
    elseif iFlag == 110 then
        self:SetArenaData(oPlayer,{})
    elseif iFlag == 111 then
        local iMonth,iDay = tonumber(mArg[2]),tonumber(mArg[3])
        local iHour,iMin = tonumber(mArg[4]) ,tonumber(mArg[5])
        self.m_DebugTime = os.time({year=iYear,month=iMonth,day=iDay,
            hour=iHour,min=iMin,sec=0})
    elseif iFlag == 112 then
        self:NewHour(1,12)
    elseif iFlag == 113 then
        local mArena = self:GetArenaData(oPlayer)
        local msg = "该玩家没有比武数据"
        if mArena then
            local point =oPlayer:ArenaScore()
            local play = mArena.play or 0
            local sTime = "无"
            if mArena.time then
                sTime = os.date("%c",mArena.time)
            end
            local sDebug = os.date("%c",self:GetDebugTime())
            msg = string.format("比武积分:%d 参加次数:%d 最后对战时间:%s,测试时间:%s",
                point,play,sTime,sDebug)
        end
        oChatMgr:HandleMsgChat(oPlayer,msg)
    elseif iFlag == 114 then
         self:RewardSingleTop(oPlayer:GetPid(),tonumber(args[1]))
    elseif iFlag == 115 then
        local iScore = oPlayer:ArenaScore()
        local iState = self:ArenaStage(iScore)
        self:CreateWeekReward(oPlayer,iState)
    elseif iFlag == 990 then
        self:CreateWeekReward(oPlayer,1)
    elseif iFlag == 991 then
        self:NewHour(1,12)
    elseif iFlag == 997 then
        local plist = oWorldMgr:GetOnlinePlayerList()
        local iCnt = 0
        local iSumPlay = 0
        for pid,obj in pairs(plist) do
            iCnt = iCnt +1
            local mData = self:GetArenaData(oPlayer)
            iSumPlay = iSumPlay + mData.play
        end
    local iAva = iSumPlay//iCnt
    local sMsg = string.format("arena info play %d %d %d",iCnt,iSumPlay,iAva)
    record.info(sMsg)
    oChatMgr:HandleMsgChat(oPlayer,sMsg)
    elseif iFlag == 1001 then
        local oMailMgr = global.oMailMgr
        local info = oMailMgr:GetMailInfo(7)
        self:RewardByMail(oPlayer:GetPid(),1001,{mailinfo=info})
    elseif iFlag == 1002 then
        local oMailMgr = global.oMailMgr
        local info = oMailMgr:GetMailInfo(7)
        self:RewardListByMail(oPlayer:GetPid(),{1001,1001},{mailinfo=info})
    elseif iFlag == 1003 then
        self.m_TopRecord = {}
        self:Dirty()

    elseif iFlag == 1004 then
        local oSceneMgr = global.oSceneMgr
        oSceneMgr:ReEnterScene(oPlayer)
    elseif iFlag == 1005 then

        self:SendMatch("EnterMatch",{id=123,data={score =1200,stage =2,}})
        self:SendMatch("EnterMatch",{id=123,data={score =1200,stage =3,}})
        self:SendMatch("EnterMatch",{id=124,data={score =1200,stage =2,}})
        self:SendMatch("EnterMatch",{id=124,data={score =1200,stage =3,}})
    elseif iFlag == 1006 then
        local oTitleMgr = global.oTitleMgr
        local mData = self:ArenaData()
        local iScore = oPlayer:ArenaScore()
        local iState = self:ArenaStage(iScore)
        local iReset =1000
        local iLastState = iState - 1
        if iLastState >= 2 then
            iReset = mData[iLastState].basescore
        end
        oPlayer:SetArenaScore(iReset)
        oPlayer.m_oThisWeek:Delete("arenamedal")
        oTitleMgr:RemoveTitles(oPlayer:GetPid(),{1001,1002,1003,1004,1005,1006,1007,1008})
        oTitleMgr:CheckTitleByType(oPlayer:GetPid(),"arena")
    elseif iFlag == 1007 then
        oPlayer:SetArenaScore(tonumber(args[1]))
    end
end




function CHuodong:TestMatch(bClose)
    self:DelTimeCb("TestMatch")
    if bClose then
        self.m_TestMatch = nil
        self.m_TestInMatchList = nil
        return
    end
    self:AddTimeCb("TestMatch",10*1000,function ()
        self:TestMatch(false)
        end)
    self.m_TestMatch = 1
    if not self.m_TestInMatchList then
        self.m_TestInMatchList = {}
    end
    local f = function ()
        local pid = 1000+math.random(20000)
        local iScore = math.random(2400)

        local mData = {
        score = iScore,
        stage = self:ArenaStage(iScore)
        }
        return {id = pid,data=mData}
    end
    local iCnt =100 + math.random(200)
    local iCont = 0
    for i=1,iCnt do
        local mNet = f()
        local pid = mNet.id
        if not self.m_TestInMatchList[pid] then
            self.m_TestInMatchList[pid] = table_deep_copy(mNet)
            self.m_TestInMatchList[pid].match = 0
            iCont = iCont +1
            self:SendMatch("EnterMatch",mNet)
        end
    end
    record.info(string.format("match debug %d",iCont))
end

function CHuodong:TestMatchResult(fightlist,mInfo)
    local f = function (pid)
        if self.m_TestInMatchList[pid].match ~= 0 then
            record.info(string.format("RE:0 %d - %d",pid,self.m_TestInMatchList[pid]))
        else
            self.m_TestInMatchList[pid].match = 1
        end
    end
    local iMax = 0
    local iMin = 0
    for _,mFight in pairs(fightlist) do
        local i1 = mFight[1]
        local i2 = mFight[2]
        f(i1)
        f(i2)
        local mInfo1 = self.m_TestInMatchList[i1].data
        local mInfo2 = self.m_TestInMatchList[i2].data
        iMin = math.min(mInfo1.stage,iMin)
        iMax = math.max(mInfo1.stage,iMax)
        if  mInfo1.stage ~= mInfo2.stage then
            record.info(string.format("timeoutlist %d:%d - %d:%d",i1,mInfo1.stage,i2,mInfo2.stage))
        end
    end
    record.info(string.format("match succ %d   @ %d:%d",#fightlist,iMax,iMin))
end