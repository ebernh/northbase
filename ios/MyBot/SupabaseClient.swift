import Foundation
import Supabase

let supabase = SupabaseClient(
  supabaseURL: URL(string: "https://ivxgpjracfctkkdhlwgm.supabase.co")!,
  supabaseKey: "sb_publishable_LZkkAwsx9q5KgIAeoZAO_A_U88rfFHL",
  options: SupabaseClientOptions(
    auth: .init(emitLocalSessionAsInitialSession: true)
  )
)
