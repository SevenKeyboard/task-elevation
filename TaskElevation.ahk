#Requires AutoHotkey v2.0.0+
;==============================================================
; TaskElevation — Creates and runs elevated Scheduled Tasks for scripts, with task path sanitization and cleanup
;
; GitHub: https://github.com/SevenKeyboard/task-scheduler
; Author: SevenKeyboard Ltd. (2026)
; License: MIT License
;
; Documentation / References:
;   ITaskFolder interface (taskschd.h)
;     https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nn-taskschd-itaskfolder
;   RunAsTask() - Auto-elevates script without UAC prompt
;     https://www.autohotkey.com/boards/viewtopic.php?t=119710
;==============================================================

/*
Example Usage:
    ;  1) Register once as admin
    if (A_IsAdmin)    {
        if (TaskElevation.register("MyApp"))
            msgBox("Registered.")
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
    static _ := this._init()
    static _init()    {
        global
        TASKELEVATION_VERSION := "2.0.0"
    }
}
class TaskElevation
{
    static _mainFolderName := "AutoHotkey.Tasks"
    static MainFolderName    {
        get  {
            return this._mainFolderName
        }
        set  {
            this._mainFolderName := this._sanitizeTaskComponent(value)
            return this._mainFolderName
        }
    }
    static _className := this._getClassName(A_ScriptHwnd)
    static _getClassName(hWnd, nMaxCount := 1024)    { ;  MAX_CLASS_NAME
        lpClassName := buffer(2 * nMaxCount, 0)
        return (dllCall("User32.dll\GetClassName", "Ptr",hWnd, "Ptr",lpClassName.Ptr, "Int",nMaxCount, "Int"))
            ? strGet(lpClassName)
            : "AutoHotkey"
    }
    static _ahkPath    {
        get  {
            loop files (ahkPath := A_AhkPath)
                ahkPath := A_LoopFileFullPath
            return ahkPath
        }
    }
    static _getKnownFolderPath(knownFolderId, dwFlags := 0x00000000, hToken := 0)    {
        static S_OK := 0
        knownFolderPath := ""
        loop 1    {
            GUID := buffer(16, 0)
            if (dllCall("Ole32.dll\IIDFromString", "Str",knownFolderId, "Ptr",GUID.ptr, "Int") !== S_OK)
                break
            if (dllCall("Shell32.dll\SHGetKnownFolderPath", "Ptr",GUID.ptr, "UInt",dwFlags, "Ptr",hToken, "Ptr*",&ppszPath:=0, "Int") !== S_OK)
                break
            knownFolderPath := strGet(ppszPath, "UTF-16")
            dllCall("Ole32.dll\CoTaskMemFree", "Ptr",ppszPath)
        }
        return knownFolderPath
    }
    static _isPathUnderProgramFiles(path)    {
        static FOLDERID_ProgramFilesX64 := "{6D809377-6AF0-444b-8957-A3773F02200E}"
            ,FOLDERID_ProgramFilesX86   := "{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}"
        pfPaths := []
        pfPaths.push(this._getKnownFolderPath(FOLDERID_ProgramFilesX86))
        if (A_Is64bitOS && A_PtrSize == 8)
            pfPaths.push(this._getKnownFolderPath(FOLDERID_ProgramFilesX64))
        b := false
        for pfPath in pfPaths    {
            if (pfPath == "")
                continue
            if (path ~= "i)^\Q" . rTrim(pfPath, "\") . "\E\\")    {
                b := true
                break
            }
        }
        return b
    }
    ;--------------------------------------------------
    static relaunchAsAdmin(subFolderName, taskPath := "", allowCommNotifyMsgFlt := true, requireProgramFiles := true)    {
        global A_Args
        static WM_COMMNOTIFY    := 0x0044
            ,MSGFLT_ALLOW       := 1
        if (requireProgramFiles)    {
            if (!this._isPathUnderProgramFiles(A_ScriptFullPath))
                return
        }
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return
        prevDHW := detectHiddenWindows(true)
        prevTMM := A_TitleMatchMode
        switch (A_IsAdmin)
        {
            default:
                setTitleMatchMode(3)
                switch (this.isRegistered(subFolderName, taskPath))
                {
                    case true:
                        prevScriptTitle := winGetTitle(A_ScriptHwnd)
                        arguments := ""
                        if (A_Args.Length)    {
                            for i, arg in A_Args
                                arguments .= (i == 1 ? "" : " ") . "`"" arg "`""
                        }
                        winSetTitle("`"" taskPath "`" " arguments, A_ScriptHwnd)
                        try  {
                            schd := comObject("Schedule.Service")
                            schd.Connect()   
                            rootFolder := schd.GetFolder("\")     
                            task := rootFolder.GetTask(taskPath)
                            task.Run(0)
                            schd := ""
                            winWait("`"" taskPath "`" ahk_class " this._className,, 2)
                            ExitApp
                        }  catch  {
                            schd := ""
                            winSetTitle(prevScriptTitle, A_ScriptHwnd)
                        }
                }
            case true:
                setTitleMatchMode(1)
                if (allowCommNotifyMsgFlt)
                    dllCall("User32.dll\ChangeWindowMessageFilterEx", "Ptr",A_ScriptHwnd, "UInt",WM_COMMNOTIFY, "UInt",MSGFLT_ALLOW, "Ptr",0)
                if (A_Args.Length && A_Args[1] == "--byscheduler")    {
                    A_Args := []
                    if (winExist("`"" taskPath "`" ahk_class " this._className))    {
                        prevTitle := winGetTitle()
                        prevArguments := subStr(prevTitle, strLen("`"" taskPath "`" ")+1)
                        winSetTitle("`"" taskPath "`"")
                        if (prevArguments !== "")
                            A_Args := this._commandLineToArgvW(prevArguments)
                    }
                }                
        }
        detectHiddenWindows(prevDHW)
        setTitleMatchMode(prevTMM)
    }
    ;--------------------------------------------------
    static register(subFolderName, taskPath := "", requireProgramFiles := true)    {
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
    static isRegistered(subFolderName, taskPath := "")    {
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return false
        try return this._isTaskExist(subFolderName, taskPath)
        return false
    }
    static unregister(subFolderName, taskPath := "")    {
        if (!A_IsAdmin)
            return false
        taskPath := taskPath !== "" ? taskPath : this.getScriptTaskPath(subFolderName)
        if (taskPath == "")
            return false
        try return this._isTaskExist(subFolderName, taskPath, true)
        return false
    }
    static unregisterAll()    {
        n := 0
        if (A_IsAdmin)
            try n := this._deleteAllTasks()
        return n
    }
    static deleteEmptyFolders()    {
        if (!A_IsAdmin)
            return 0
        n := 0
        try  {
            schd := comObject("Schedule.Service")
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
    static getScriptTaskPath(subFolderName)    {
        subFolderName   := this._sanitizeTaskComponent(subFolderName)
        fileName        := A_ScriptName
        cmdLine := A_IsCompiled ? "`"" A_ScriptFullpath "`"" : "`"" this._ahkPath "`"" A_Space "`"" A_ScriptFullpath "`""
        pathCrc := this._crc32Utf16Bytes(&cmdLine)
        sid := this._ProcessUserSid
        userCrc := (sid !== "") ? this._crc32Utf16Bytes(&sid) : 0
        path := format(this._mainFolderName "\" subFolderName "\{1:}@{2:08X};user={3:08X}", fileName, pathCrc, userCrc)
        return (strLen(path) <= 238 ? path : "")
    }
    static getFileTaskPath(subFolderName, filePath, fileName)    {
        subFolderName   := this._sanitizeTaskComponent(subFolderName)
        fileName        := this._sanitizeTaskComponent(fileName)
        pathCrc := this._crc32Utf16Bytes(&filePath)
        sid := this._ProcessUserSid
        userCrc := (sid !== "") ? this._crc32Utf16Bytes(&sid) : 0
        path := format(this._mainFolderName "\" subFolderName "\{1:}@{2:08X};user={3:08X}", fileName, pathCrc, userCrc)
        return (strLen(path) <= 238 ? path : "")
    }
    static _crc32Utf16Bytes(&data)    {
        return dllCall("ntdll.dll\RtlComputeCrc32"
            ,"UInt",0 ;  dwInitial
            ,"WStr",data ;  pData
            ,"UInt",strPut(data, "UTF-16") - 2 ;  iLen
            ,"UInt")
    }
    ;--------------------------------------------------
    static _isTaskExist(subFolderName, taskPath, delete := false)    {
        b := false
        schd := comObject("Schedule.Service")
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
    static _registerTask(subFolderName, taskPath)    {
        static TASK_CREATE                  := 0x2
            ,TASK_LOGON_INTERACTIVE_TOKEN   := 3
        sid := this._ProcessUserSid
        if (sid == "")
            return false
        schd := comObject("Schedule.Service")
        schd.Connect()
        rootFolder := schd.GetFolder("\")
        exist := false
        try task := rootFolder.GetTask(taskPath), exist := true
        if (!exist)    {
            xml := format('
                (LTrim
                    <?xml version="1.0" ?>
                    <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
                        <Principals>
                            <Principal id="Author">
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
                )'
                ,this._xmlEscape(sid)
                ,this._xmlEscape(A_IsCompiled ? A_ScriptFullpath : this._ahkPath)
                ,this._xmlEscape(A_IsCompiled ? "--byscheduler" : "`"" A_ScriptFullpath "`" --byscheduler")
                ,this._xmlEscape(A_WorkingDir))
            rootFolder.RegisterTask(taskPath
                ,xml
                ,TASK_CREATE
                ,""
                ,""
                ,TASK_LOGON_INTERACTIVE_TOKEN)
        }
        schd := ""
        return true            
    }
    static _xmlEscape(s)    {
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
        s := strReplace(s, "`"", "&quot;")
        s := strReplace(s, "'", "&apos;")
        return s
    }
    static _deleteAllTasks(includeFolder := true)    {
        n := 0
        schd := comObject("Schedule.Service")
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
    static _commandLineToArgvW(cmdLine := "")    {
        args := []
        if (pArgs := dllCall("Shell32.dll\CommandLineToArgvW", "WStr",cmdLine, "Ptr*",&nArgs:=0, "Ptr"))    {
            loop nArgs
                args.push(strGet(numGet((A_Index - 1) * A_PtrSize + pArgs, "Ptr"), "UTF-16"))
            dllCall("Kernel32.dll\LocalFree", "Ptr",pArgs)
        }
        return args
    }
    ;--------------------------------------------------
    static _sanitizeTaskComponent(name, defaultName := "Unnamed")    { ;  My:Task*Name -> My%3ATask%2AName
        static escapeChars          := map("%",true, "<",true, ">",true, ":",true, "`"",true, "/",true, "\",true, "|",true, "?",true, "*",true)
            ,reservedDeviceNames    := ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³"]
        if (name == "")
            return defaultName
        out := ""
        loop parse, name
        {
            ch := A_LoopField, code := ord(ch)
            if (0 <= code && code < 0x20)    {
                out .= format("%{:02X}", code)
                continue
            }
            if (escapeChars.has(ch))    {
                out .= format("%{:02X}", code)
                continue
            }
            out .= ch
        }
        if (regExMatch(out, "sD)^(.*?)([ .]+)$", &m))
            out := m[1] . strReplace(strReplace(m[2], " ", "%20"), ".", "%2E")
        for deviceName in reservedDeviceNames    {
            if (out ~= "iD)^\Q" . deviceName . "\E(\.|$)")    {
                out := "_" . out
                break
            }
        }
        return (out == "" ? defaultName : out)
    }
    ;--------------------------------------------------
    static _ProcessUserSid    {
        get  {
            static sid := ""
            if (sid == "")
                sid := this._getProcessUserSid()
            return sid
        }
    }
    static _getProcessUserSid()    { ;  https://github.com/SevenKeyboard/get-process-user-sid/blob/main-ahkv2.0/getProcessUserSid.ahk
        static TOKEN_QUERY  := 0x0008
            ,TokenUser      := 1
        if (!dllCall("Advapi32.dll\OpenProcessToken"
                ,"Ptr",dllCall("Kernel32.dll\GetCurrentProcess", "Ptr") ;  -1
                ,"UInt",TOKEN_QUERY
                ,"Ptr*",&tokenHandle := 0
                ,"Int"))    {
            return ""
        }
        dllCall("Advapi32.dll\GetTokenInformation"
            ,"Ptr",tokenHandle
            ,"Int",TokenUser
            ,"Ptr",0
            ,"UInt",0
            ,"UInt*",&tokenInformationLength := 0
            ,"Int")
        if (tokenInformationLength == 0)    {
            if (tokenHandle)
                dllCall("Kernel32.dll\CloseHandle", "Ptr",tokenHandle, "Int"), tokenHandle := 0
            return ""
        }
        tokenInformation := buffer(tokenInformationLength, 0)
        bResult := dllCall("Advapi32.dll\GetTokenInformation"
            ,"Ptr",tokenHandle
            ,"Int",TokenUser
            ,"Ptr",tokenInformation.Ptr
            ,"UInt",tokenInformationLength
            ,"UInt*",&_ := 0
            ,"Int")
        if (tokenHandle)
            dllCall("Kernel32.dll\CloseHandle", "Ptr",tokenHandle, "Int"), tokenHandle := 0
        if (!bResult)
            return ""
        if (!pSid := numGet(tokenInformation, 0, "Ptr"))
            return ""
        if (!dllCall("Advapi32.dll\ConvertSidToStringSidW", "Ptr",pSid, "Ptr*",&pStringSid := 0, "Int"))
            return ""
        stringSid := strGet(pStringSid, "UTF-16")
        dllCall("Kernel32.dll\LocalFree", "Ptr",pStringSid, "Ptr")
        return stringSid
    }
}