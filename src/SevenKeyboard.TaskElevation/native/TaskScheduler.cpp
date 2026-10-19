// Task Scheduler COM boundary. The C# layer owns task naming, XML and argument encoding.
#include <windows.h>
#include <taskschd.h>
#include <sddl.h>
#include <vector>
#include <atlbase.h>
#include <atlcomcli.h>
#include <new>
#include <cwchar>

#define CHECK(call) do { HRESULT result_ = (call); if (FAILED(result_)) return result_; } while (false)

class ComApartment
{
public:
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~ComApartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};

static bool Missing(HRESULT hr)
{
    return hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
        hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND);
}

static bool Equals(const CComBSTR& actual, const wchar_t* expected, bool ignoreCase = false)
{
    return actual && (ignoreCase ? _wcsicmp(actual, expected) == 0 : wcscmp(actual, expected) == 0);
}

static HRESULT SameUser(const wchar_t* actual, const wchar_t* expected, bool& same)
{
    same = false;
    if (!actual) return S_OK;
    if (_wcsicmp(actual, expected) == 0) { same = true; return S_OK; }
    // Scheduler may normalize a SID to an account name (e.g. MACHINE\user).
    DWORD sidSize = 0, domainSize = 0;
    SID_NAME_USE use;
    LookupAccountNameW(nullptr, actual, nullptr, &sidSize, nullptr, &domainSize, &use);
    DWORD error = GetLastError();
    if (error == ERROR_NONE_MAPPED) return S_OK;
    if (error != ERROR_INSUFFICIENT_BUFFER) return HRESULT_FROM_WIN32(error);
    std::vector<BYTE> sid(sidSize);
    std::vector<wchar_t> domain(domainSize);
    if (!LookupAccountNameW(nullptr, actual, sid.data(), &sidSize, domain.data(), &domainSize, &use))
        return HRESULT_FROM_WIN32(GetLastError());
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(sid.data(), &text))
        return HRESULT_FROM_WIN32(GetLastError());
    same = _wcsicmp(text, expected) == 0;
    LocalFree(text);
    return S_OK;
}
static HRESULT OpenChild(ITaskFolder* parent, const wchar_t* name, bool create, CComPtr<ITaskFolder>& child)
{
    HRESULT hr = parent->GetFolder(CComBSTR(name), &child);
    if (create && Missing(hr))
    {
        CComVariant empty;
        hr = parent->CreateFolder(CComBSTR(name), empty, &child);
        if (hr == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS))
            hr = parent->GetFolder(CComBSTR(name), &child);
    }
    return hr;
}

// Only the same user's single-action task for this executable may be updated/deleted.
static HRESULT Inspect(IRegisteredTask* task, const wchar_t* command, const wchar_t* arguments,
    const wchar_t* directory, const wchar_t* sid, bool& owned, bool& compatible)
{
    owned = compatible = false;
    CComPtr<ITaskDefinition> definition;
    CHECK(task->get_Definition(&definition));
    CComPtr<IPrincipal> principal;
    CHECK(definition->get_Principal(&principal));
    CComBSTR user;
    CHECK(principal->get_UserId(&user));
    bool sameUser = false;
    CHECK(SameUser(user, sid, sameUser));
    if (!sameUser) return S_OK;
    CComPtr<IActionCollection> actions;
    CHECK(definition->get_Actions(&actions));
    LONG count = 0;
    CHECK(actions->get_Count(&count));
    if (count != 1) return S_OK;
    CComPtr<IAction> action;
    CHECK(actions->get_Item(1, &action));
    CComPtr<IExecAction> exec;
    HRESULT hr = action->QueryInterface(IID_PPV_ARGS(&exec));
    if (hr == E_NOINTERFACE) return S_OK;
    CHECK(hr);
    CComBSTR path, args, cwd;
    CHECK(exec->get_Path(&path));
    CHECK(exec->get_Arguments(&args));
    CHECK(exec->get_WorkingDirectory(&cwd));
    owned = Equals(path, command, true) &&
        Equals(args, arguments);
    if (!owned || !Equals(cwd, directory, true)) return S_OK;
    TASK_RUNLEVEL_TYPE level;
    TASK_LOGON_TYPE logon;
    CHECK(principal->get_RunLevel(&level));
    CHECK(principal->get_LogonType(&logon));
    if (level != TASK_RUNLEVEL_HIGHEST || logon != TASK_LOGON_INTERACTIVE_TOKEN) return S_OK;
    CComPtr<ITaskSettings> settings;
    CHECK(definition->get_Settings(&settings));
    VARIANT_BOOL enabled, demand, battery, stopOnBattery;
    TASK_INSTANCES_POLICY instances;
    CHECK(settings->get_Enabled(&enabled));
    CHECK(settings->get_AllowDemandStart(&demand));
    CHECK(settings->get_DisallowStartIfOnBatteries(&battery));
    CHECK(settings->get_StopIfGoingOnBatteries(&stopOnBattery));
    CHECK(settings->get_MultipleInstances(&instances));
    CComBSTR limit;
    CHECK(settings->get_ExecutionTimeLimit(&limit));
    compatible = enabled != VARIANT_FALSE && demand != VARIANT_FALSE &&
        battery == VARIANT_FALSE && stopOnBattery == VARIANT_FALSE &&
        instances == TASK_INSTANCES_PARALLEL && Equals(limit, L"PT0S");
    return S_OK;
}

static bool IsEmpty(ITaskFolder* folder)
{
    CComPtr<IRegisteredTaskCollection> tasks;
    CComPtr<ITaskFolderCollection> folders;
    LONG taskCount = 0, folderCount = 0;
    return SUCCEEDED(folder->GetTasks(TASK_ENUM_HIDDEN, &tasks)) &&
        SUCCEEDED(folder->GetFolders(0, &folders)) &&
        SUCCEEDED(tasks->get_Count(&taskCount)) && SUCCEEDED(folders->get_Count(&folderCount)) &&
        taskCount == 0 && folderCount == 0;
}

extern "C" __declspec(dllexport) HRESULT __stdcall TaskElevationExecute(
    int operation, const wchar_t* mainName, const wchar_t* subName, const wchar_t* name,
    const wchar_t* command, const wchar_t* arguments, const wchar_t* directory,
    const wchar_t* sid, const wchar_t* value) noexcept
{
    if (operation < 0 || operation > 3 || !mainName || !subName || !name ||
        !command || !arguments || !directory || !sid || !value) return E_INVALIDARG;
    try
    {
        ComApartment apartment;
        // An existing MTA is also valid for the scheduler; do not uninitialize it.
        if (FAILED(apartment.result) && apartment.result != RPC_E_CHANGED_MODE)
            return apartment.result;
        CComPtr<ITaskService> service;
        CHECK(service.CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER));
        CComVariant empty;
        CHECK(service->Connect(empty, empty, empty, empty));
        CComPtr<ITaskFolder> root, mainFolder, folder;
        CHECK(service->GetFolder(CComBSTR(L"\\"), &root));
        HRESULT hr = OpenChild(root, mainName, operation == 0, mainFolder);
        if (Missing(hr)) return S_FALSE;
        CHECK(hr);
        hr = OpenChild(mainFolder, subName, operation == 0, folder);
        if (Missing(hr)) return S_FALSE;
        CHECK(hr);
        CComBSTR taskName(name);
        CComPtr<IRegisteredTask> task;
        hr = folder->GetTask(taskName, &task);
        bool owned = false, compatible = false;
        if (!Missing(hr))
        {
            CHECK(hr);
            CHECK(Inspect(task, command, arguments, directory, sid, owned, compatible));
        }
        if (operation == 0)
        {
            if (task && !owned) return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
            // TASK_CREATE avoids replacing a task which appeared after our inspection.
            LONG flags = task ? TASK_UPDATE : TASK_CREATE;
            task.Release();
            CComVariant user(sid);
            CHECK(folder->RegisterTask(taskName, CComBSTR(value), flags,
                user, empty, TASK_LOGON_INTERACTIVE_TOKEN, empty, &task));
            CHECK(Inspect(task, command, arguments, directory, sid, owned, compatible));
            return compatible ? S_OK : E_FAIL;
        }
        if (operation == 1) return compatible ? S_OK : S_FALSE;
        if (operation == 3)
        {
            if (!owned) return S_FALSE;
            CHECK(folder->DeleteTask(taskName, 0));
            // Best-effort cleanup; other users' tasks and nonempty folders are retained.
            if (IsEmpty(folder))
                mainFolder->DeleteFolder(CComBSTR(subName), 0);
            if (IsEmpty(mainFolder))
                root->DeleteFolder(CComBSTR(mainName), 0);
            return S_OK;
        }
        if (!compatible) return S_FALSE;
        CComVariant parameters(value); // Single BSTR maps to $(Arg0).
        CComPtr<IRunningTask> running;
        return task->Run(parameters, &running);
    }
    catch (const ATL::CAtlException& e) { return e.m_hr; }
    catch (const std::bad_alloc&) { return E_OUTOFMEMORY; }
    catch (...) { return E_FAIL; }
}
