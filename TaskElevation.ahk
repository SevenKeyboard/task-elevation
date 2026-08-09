#Requires AutoHotkey v1.1.37+
;==============================================================
; TaskElevation — Creates and runs elevated Scheduled Tasks for scripts, with task path sanitization and cleanup
;
; GitHub: https://github.com/SevenKeyboard/task-elevation
; Author: SevenKeyboard Ltd. (2026)
; License: MIT License
;
; Documentation / References:
;   ITaskFolder interface (taskschd.h)
;     https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nn-taskschd-itaskfolder
;   RunAsTask() - Auto-elevates script without UAC prompt
;     https://www.autohotkey.com/boards/viewtopic.php?t=4334
;==============================================================

/*
Example Usage:
    ;  1) Register once as admin
    if (A_IsAdmin)    {
        if (TaskElevation.register("MyApp"))
            msgBox % "Registered."
    }

    ;  2) Normal runs: relaunch via the scheduled task (if registered)
    ;     Defaults:
    ;       - allowCommNotifyMsgFlt=true: enables WM_COMMNOTIFY handoff (e.g. #SingleInstance Force).
    ;       - requireProgramFiles=true  : recommended for distribution (only run from Program Files).
    ;     Notes:
    ;       - requireProgramFiles and allowCommNotifyMsgFlt are mutually exclusive in this design.
    ;       - If you use a mutex/lockfile/etc. for single-instance control, prefer allowCommNotifyMsgFlt=false.
    ;       - Disabling requireProgramFiles is generally not recommended.
    TaskElevation.relaunchAsAdmin("MyApp")
*/

class VersionManager_TaskElevation
{
    static _ := VersionManager_TaskElevation._init()
    _init()    {
        global
        TASKELEVATION_VERSION := "2.1.1"
    }
}
class TaskElevation
{
    static _mainFolderName := "AutoHotkey.Tasks"
    MainFolderName    {
        get  {
            return this._mainFolderName
        }
        set  {
            this._mainFolderName := this._sanitizeTaskComponent(value)
            return this._mainFolderName
        }
    }
    ;--------------------------------------------------
    static _taskCommand := ""
    TaskCommand    {
        get  {
            return this._taskCommand
        }
        set  {
            this._taskCommand := value
            return this._taskCommand
        }
    }
    static _taskArguments := ""
    TaskArguments    {
        get  {
            return this._taskArguments
        }
        set  {
            this._taskArguments := value
            return this._taskArguments
        }
    }
    static _taskWorkingDir := ""
    TaskWorkingDir    {
        get  {
            return this._taskWorkingDir
        }
        set  {
            this._taskWorkingDir := value
            return this._taskWorkingDir
        }
    }
    _getTaskCommand()    {
        return this._taskCommand !== ""
            ? this._taskCommand
            : (A_IsCompiled ? A_ScriptFullPath : this._ahkPath)
    }
    _getTaskArguments()    {
        return this._taskArguments !== ""
            ? this._taskArguments
            : (A_IsCompiled ? "--byscheduler" : """" A_ScriptFullPath """ --byscheduler")
    }
    _getTaskWorkingDir()    {
        return this._taskWorkingDir !== ""
            ? this._taskWorkingDir
            : A_WorkingDir
    }
    ;--------------------------------------------------
    static _className := TaskElevation._getClassName(A_ScriptHwnd)
    _getClassName(hWnd, nMaxCount := 1024)    { ;  MAX_CLASS_NAME
        varSetCapacity(lpClassName, (A_IsUnicode ? 2 : 1) * nMaxCount, 0)
        return (dllCall("User32.dll\GetClassName", "Ptr",hWnd, "Ptr",&lpClassName, "Int",nMaxCount, "Int"))
            ? strGet(&lpClassName)
            : "AutoHotkey"
    }
    _ahkPath    {
        get  {
            loop Files, % (ahkPath := A_AhkPath)
                ahkPath := A_LoopFileFullPath
            return ahkPath
        }
    }
    _getKnownFolderPath(knownFolderId, dwFlags := 0x00000000, hToken := 0)    {
        static S_OK := 0
        knownFolderPath := ""
        loop 1    {
            varSetCapacity(GUID, 16, 0)
            if (dllCall("Ole32.dll\IIDFromString", "Str",knownFolderId, "Ptr",&GUID, "Int") !== S_OK)
                break
            if (dllCall("Shell32.dll\SHGetKnownFolderPath", "Ptr",&GUID, "UInt",dwFlags, "Ptr",hToken, "Ptr*",ppszPath, "Int") !== S_OK)
                break
            knownFolderPath := strGet(ppszPath, "UTF-16")
            dllCall("Ole32.dll\CoTaskMemFree", "Ptr",ppszPath)
        }
        return knownFolderPath
    }
    _isPathUnderProgramFiles(path)    {
        static FOLDERID_ProgramFilesX64 := "{6D809377-6AF0-444b-8957-A3773F02200E}"
            ,FOLDERID_ProgramFilesX86   := "{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}"
        pfPaths := []
        pfPaths.push(this._getKnownFolderPath(FOLDERID_ProgramFilesX86))
        if (A_Is64bitOS && A_PtrSize == 8)
            pfPaths.push(this._getKnownFolderPath(FOLDERID_ProgramFilesX64))
        b := false
        for _,pfPath in pfPaths    {
            if (pfPath == "")
                continue
            if (path ~= "i)^" . this._regExQuoteLiteral(rTrim(pfPath, "\")) . "\\")    {
                b := true
                break
            }
        }
        return b
    }
    ;--------------------------------------------------
    relaunchAsAdmin(subFolderName, taskPath := "", allowCommNotifyMsgFlt := true, requireProgramFiles := true)    {
        static WM_COMMNOTIFY    := 0x0044
            ,MSGFLT_ALLOW       := 1
        if (requireProgramFiles)    {
            if (!this._isPathUnderProgramFiles(A_ScriptFullPath))
                return
        }
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return
        prevDHW := A_DetectHiddenWindows
        prevTMM := A_TitleMatchMode
        detectHiddenWindows % "On"
        switch (A_IsAdmin)
        {
            default:
                setTitleMatchMode 3
                switch (this.isRegistered(subFolderName, taskPath))
                {
                    case true:
                        winGetTitle prevScriptTitle, % "ahk_id "  A_ScriptHwnd
                        arguments := ""
                        if (A_Args.length())    {
                            for i, arg in A_Args
                                arguments .= (i == 1 ? "" : " ") . """" arg """"
                        }
                        winSetTitle % "ahk_id "  A_ScriptHwnd,, % """" taskPath """ " arguments
                        try  {
                            schd := comObjCreate("Schedule.Service")
                            schd.Connect()   
                            rootFolder := schd.GetFolder("\")     
                            task := rootFolder.GetTask(taskPath)
                            task.Run(0)
                            schd := ""
                            winWait % """" taskPath """ ahk_class " this._className,, 2
                            ExitApp
                        }  catch  {
                            schd := ""
                            winSetTitle % "ahk_id "  A_ScriptHwnd,, % prevScriptTitle
                        }
                }
            case true:
                setTitleMatchMode 1
                if (allowCommNotifyMsgFlt)
                    dllCall("User32.dll\ChangeWindowMessageFilterEx", "Ptr",A_ScriptHwnd, "UInt",WM_COMMNOTIFY, "UInt",MSGFLT_ALLOW, "Ptr",0)
                if (A_Args.length() && A_Args[1] == "--byscheduler")    {
                    A_Args := []
                    if (winExist("""" taskPath """ ahk_class " this._className))    {
                        winGetTitle prevTitle
                        prevArguments := subStr(prevTitle, strLen("""" taskPath """ ")+1)
                        winSetTitle % """" taskPath """"
                        if (prevArguments !== "")
                            A_Args := this._commandLineToArgvW(prevArguments)
                    }
                }                
        }
        detectHiddenWindows % prevDHW
        setTitleMatchMode % prevTMM
    }
    ;--------------------------------------------------
    register(subFolderName, taskPath := "", requireProgramFiles := true)    {
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return false
        if (requireProgramFiles)    {
            if (!this._isPathUnderProgramFiles(A_ScriptFullPath))
                return false
        }
        if (A_IsAdmin)
            try return this._registerTask(subFolderName, taskPath)
        return false
    }
    isRegistered(subFolderName, taskPath := "")    {
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return false
        try return this._isTaskExist(subFolderName, taskPath)
        return false
    }
    unregister(subFolderName, taskPath := "")    {
        if (!A_IsAdmin)
            return false
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return false
        try return this._isTaskExist(subFolderName, taskPath, true)
        return false
    }
    unregisterAll()    {
        n := 0
        if (A_IsAdmin)
            try n := this._deleteAllTasks()
        return n
    }
    deleteEmptyFolders()    {
        if (!A_IsAdmin)
            return 0
        n := 0
        try  {
            schd := comObjCreate("Schedule.Service")
            schd.Connect()
            mainFolder := schd.GetFolder("\" this._mainFolderName)
            for subFolder in mainFolder.GetFolders(0)    {
                taskFolder := schd.GetFolder("\" this._mainFolderName "\" subFolder.Name)
                if (taskFolder.GetTasks(0).count() == 0)    {
                    mainFolder.DeleteFolder("\" subFolder.Name, 0)
                    ++n
                }
            }
            rootFolder := schd.GetFolder("\")
            if (mainFolder.GetTasks(0).count() == 0 && mainFolder.GetFolders(0).count() == 0)    {
                rootFolder.DeleteFolder("\" this._mainFolderName, 0)
                ++n
            }
        }
        return n
    }
    getScriptTaskPath(subFolderName)    {
        subFolderName   := this._sanitizeTaskComponent(subFolderName)
        fileName        := A_ScriptName
        cmdLine := A_IsCompiled ? """" A_ScriptFullpath """" : """" this._ahkPath """" A_Space """" A_ScriptFullpath """"
        pathCrc := this._crc32Utf16Bytes(cmdLine)
        sid := this._ProcessUserSid
        userCrc := (sid !== "") ? this._crc32Utf16Bytes(sid) : 0
        path := format(this._mainFolderName "\" subFolderName "\{1:}@{2:08X};user={3:08X}", fileName, pathCrc, userCrc)
        return (strLen(path) <= 238 ? path : "")
    }
    getFileTaskPath(subFolderName, filePath, fileName)    {
        subFolderName   := this._sanitizeTaskComponent(subFolderName)
        fileName        := this._sanitizeTaskComponent(fileName)
        pathCrc := this._crc32Utf16Bytes(filePath)
        sid := this._ProcessUserSid
        userCrc := (sid !== "") ? this._crc32Utf16Bytes(sid) : 0
        path := format(this._mainFolderName "\" subFolderName "\{1:}@{2:08X};user={3:08X}", fileName, pathCrc, userCrc)
        return (strLen(path) <= 238 ? path : "")
    }
    _crc32Utf16Bytes(byRef data)    {
        return dllCall("ntdll.dll\RtlComputeCrc32"
            ,"UInt",0 ;  dwInitial
            ,"WStr",data ;  pData
            ,"UInt",(strPut(data, "UTF-16") - 1) * 2 ;  iLen
            ,"UInt")
    }
    ;--------------------------------------------------
    _isTaskExist(subFolderName, taskPath, delete := false)    {
        b := false
        schd := comObjCreate("Schedule.Service")
        schd.Connect()
        mainFolder      := schd.GetFolder("\" this._mainFolderName)
        subFolderName   := this._sanitizeTaskComponent(subFolderName)
        for subFolder in mainFolder.GetFolders(0)    {
            if (subFolderName == subFolder.Name)    {
                taskFolder := schd.GetFolder("\" this._mainFolderName "\" subFolder.Name)
                for task In taskFolder.GetTasks(0)    {
                    if (this._mainFolderName "\" subFolder.Name "\" task.Name == taskPath)    {
                        if (delete)
                            taskFolder.DeleteTask(task.Name, 0)
                        b := true
                    }
                }
            }
        }
        schd := ""
        return b
    }
    _registerTask(subFolderName, taskPath)    {
        static TASK_CREATE                  := 0x2
            ,TASK_LOGON_INTERACTIVE_TOKEN   := 3
        sid := this._ProcessUserSid
        if (sid == "")
            return false
        schd := comObjCreate("Schedule.Service")
        schd.Connect()
        rootFolder := schd.GetFolder("\")
        subFolderName := this._sanitizeTaskComponent(subFolderName)
        taskFolderPath := "\" this._mainFolderName "\" subFolderName
        try taskFolder := schd.GetFolder(taskFolderPath)
        catch
            taskFolder := rootFolder.CreateFolder(this._mainFolderName "\" subFolderName)
        splitPath taskPath, taskName
        exist := false
        try task := taskFolder.GetTask(taskName), exist := true
        if (!exist)    {
            xml := format("
                (LTrim
                    <?xml version=""1.0"" ?>
                    <Task version=""1.2"" xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task"">
                        <Principals>
                            <Principal id=""Author"">
                                <UserId>{1:}</UserId>
                                <LogonType>InteractiveToken</LogonType>
                                <RunLevel>HighestAvailable</RunLevel>
                            </Principal>
                        </Principals>
                        <Settings>
                            <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
                            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
                            <AllowHardTerminate>true</AllowHardTerminate>
                            <AllowStartOnDemand>true</AllowStartOnDemand>
                            <Enabled>true</Enabled>
                            <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
                        </Settings>
                        <Actions>
                            <Exec>
                                <Command>{2:}</Command>
                                <Arguments>{3:}</Arguments>
                                <WorkingDirectory>{4:}</WorkingDirectory>
                            </Exec>
                        </Actions>
                    </Task>
                )"
                ,this._xmlEscape(sid)
                ,this._xmlEscape(this._getTaskCommand())
                ,this._xmlEscape(this._getTaskArguments())
                ,this._xmlEscape(this._getTaskWorkingDir()))
            taskFolder.RegisterTask(taskName
                ,xml
                ,TASK_CREATE
                ,""
                ,""
                ,TASK_LOGON_INTERACTIVE_TOKEN)
        }
        schd := ""
        return true            
    }
    _xmlEscape(s)    {
        /*
        https://www.w3.org/TR/xml/

        Character Range
        [2]   	Char	   ::=   	#x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]	/ * any Unicode character, excluding the surrogate blocks, FFFE, and FFFF. * /
        The mechanism for encoding character code points into bit patterns may vary from entity to entity. All XML processors MUST accept the UTF-8 and UTF-16 encodings of Unicode [Unicode]; the mechanisms for signaling which of the two is in use, or for bringing other encodings into play, are discussed later, in 4.3.3 Character Encoding in Entities.
        */
        s := regExReplace(s, "[^\x09\x0A\x0D\x20-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]+")

        s := strReplace(s, "&", "&amp;")
        s := strReplace(s, "<", "&lt;")
        s := strReplace(s, ">", "&gt;")
        s := strReplace(s, """", "&quot;")
        s := strReplace(s, "'", "&apos;")
        return s
    }
    _deleteAllTasks(includeFolder := true)    {
        n := 0
        schd := comObjCreate("Schedule.Service")
        schd.Connect()
        mainFolder := schd.GetFolder("\" this._mainFolderName)
        for subFolder in mainFolder.GetFolders(0)    {
            taskFolder := schd.GetFolder("\" this._mainFolderName "\" subFolder.Name)
            for task In taskFolder.GetTasks(0)    {
                taskFolder.DeleteTask(task.Name, 0)
                ++n
            }
            if (includeFolder)
                mainFolder.DeleteFolder("\" subFolder.Name, 0)
        }
        if (includeFolder)
            schd.GetFolder("\").DeleteFolder("\" this._mainFolderName, 0)
        schd := ""
        return n
    }
    _commandLineToArgvW(cmdLine := "")    {
        args := []
        if (pArgs := dllCall("Shell32.dll\CommandLineToArgvW", "WStr",cmdLine, "Ptr*",nArgs, "Ptr"))    {
            loop % nArgs
                args.push(strGet(numGet((A_Index - 1) * A_PtrSize + pArgs, "Ptr"), "UTF-16"))
            dllCall("Kernel32.dll\LocalFree", "Ptr",pArgs)
        }
        return args
    }
    ;--------------------------------------------------
    _sanitizeTaskComponent(name, defaultName := "Unnamed")    { ;  My:Task*Name -> My%3ATask%2AName
        static escapeChars          := object("%",true, "<",true, ">",true, ":",true, """",true, "/",true, "\",true, "|",true, "?",true, "*",true)
            ,reservedDeviceNames    := ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³"]
        if (name == "")
            return defaultName
        out := ""
        loop Parse, % name
        {
            ch := A_LoopField, code := asc(ch)
            if (0 <= code && code < 0x20)    {
                out .= format("%{:02X}", code)
                continue
            }
            if (escapeChars.hasKey(ch))    {
                out .= format("%{:02X}", code)
                continue
            }
            out .= ch
        }
        if (regExMatch(out, "sDO)^(.*?)([ .]+)$", m))
            out := m[1] . strReplace(strReplace(m[2], " ", "%20"), ".", "%2E")
        for _,deviceName in reservedDeviceNames    {
            if (out ~= "iD)^" . this._regExQuoteLiteral(deviceName) . "(\.|$)")    {
                out := "_" . out
                break
            }
        }
        return (out == "" ? defaultName : out)
    }
    ;--------------------------------------------------
    _ProcessUserSid    {
        get  {
            static sid := ""
            if (sid == "")
                sid := this._getProcessUserSid()
            return sid
        }
    }
    _getProcessUserSid()    { ;  https://github.com/SevenKeyboard/get-process-user-sid/blob/main-ahkv1.1/getProcessUserSid.ahk
        static TOKEN_QUERY  := 0x0008
            ,TokenUser      := 1
        if (!dllCall("Advapi32.dll\OpenProcessToken"
                ,"Ptr",dllCall("Kernel32.dll\GetCurrentProcess", "Ptr") ;  -1
                ,"UInt",TOKEN_QUERY
                ,"Ptr*",tokenHandle
                ,"Int"))    {
            return ""
        }
        dllCall("Advapi32.dll\GetTokenInformation"
            ,"Ptr",tokenHandle
            ,"Int",TokenUser
            ,"Ptr",0
            ,"UInt",0
            ,"UInt*",tokenInformationLength := 0
            ,"Int")
        if (tokenInformationLength == 0)    {
            if (tokenHandle)
                dllCall("Kernel32.dll\CloseHandle", "Ptr",tokenHandle, "Int"), tokenHandle := 0
            return ""
        }
        varSetCapacity(tokenInformation, tokenInformationLength, 0)
        bResult := dllCall("Advapi32.dll\GetTokenInformation"
            ,"Ptr",tokenHandle
            ,"Int",TokenUser
            ,"Ptr",&tokenInformation
            ,"UInt",tokenInformationLength
            ,"UInt*",_
            ,"Int")
        if (tokenHandle)
            dllCall("Kernel32.dll\CloseHandle", "Ptr",tokenHandle, "Int"), tokenHandle := 0
        if (!bResult)
            return ""
        if (!pSid := numGet(tokenInformation, 0, "Ptr"))
            return ""
        if (!dllCall("Advapi32.dll\ConvertSidToStringSidW", "Ptr",pSid, "Ptr*",pStringSid, "Int"))
            return ""
        stringSid := strGet(pStringSid, "UTF-16")
        dllCall("Kernel32.dll\LocalFree", "Ptr",pStringSid, "Ptr")
        return stringSid
    }
    ;--------------------------------------------------
    _regExQuoteLiteral(text)    {
        return "\Q" . regExReplace(text, "\\E", "\E\\E\Q") . "\E"
    }
}
